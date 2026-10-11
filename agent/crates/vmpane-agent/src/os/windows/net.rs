//! Windows interface addresses (GetAdaptersAddresses) and listening sockets (GetExtendedTcpTable /
//! GetExtendedUdpTable), with the owning process's image name.

use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr};

use vmpane_agent_proto::methods::{ListeningPort, NetInterface, PortProto};
use windows::Win32::Foundation::{
    CloseHandle, ERROR_BUFFER_OVERFLOW, ERROR_INSUFFICIENT_BUFFER, NO_ERROR,
};
use windows::Win32::NetworkManagement::IpHelper::{
    GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST, GetAdaptersAddresses,
    GetExtendedTcpTable, GetExtendedUdpTable, IP_ADAPTER_ADDRESSES_LH, MIB_TCP6ROW_OWNER_PID,
    MIB_TCPROW_OWNER_PID, MIB_UDP6ROW_OWNER_PID, MIB_UDPROW_OWNER_PID,
    TCP_TABLE_OWNER_PID_LISTENER, UDP_TABLE_OWNER_PID,
};
use windows::Win32::Networking::WinSock::{
    AF_INET, AF_INET6, AF_UNSPEC, SOCKADDR_IN, SOCKADDR_IN6,
};
use windows::Win32::System::Threading::{
    OpenProcess, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
};
use windows::core::PWSTR;

const LOOPBACK_IF_TYPE: u32 = 24;

/// Calls `fill(buffer, size)` with a growing buffer until it fits; returns the filled buffer.
fn sized_call(mut fill: impl FnMut(*mut u8, &mut u32) -> u32) -> std::io::Result<Vec<u64>> {
    let mut size: u32 = 16 * 1024;
    for _ in 0..8 {
        // u64 elements keep the buffer 8-byte aligned for the structs the API writes.
        let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
        match fill(buffer.as_mut_ptr().cast(), &mut size) {
            code if code == NO_ERROR.0 => return Ok(buffer),
            code if code == ERROR_BUFFER_OVERFLOW.0 || code == ERROR_INSUFFICIENT_BUFFER.0 => {
                continue;
            }
            code => return Err(std::io::Error::from_raw_os_error(code as i32)),
        }
    }
    Err(std::io::Error::other("the table kept growing"))
}

fn wide(text: PWSTR) -> String {
    if text.is_null() {
        return String::new();
    }
    // SAFETY: the API hands out NUL-terminated wide strings that live as long as its buffer.
    unsafe { text.to_string() }.unwrap_or_default()
}

pub fn interfaces() -> std::io::Result<Vec<NetInterface>> {
    let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    let buffer = sized_call(|buf, size| {
        // SAFETY: `buf` holds `size` bytes; the API writes a linked list inside it.
        unsafe { GetAdaptersAddresses(u32::from(AF_UNSPEC.0), flags, None, Some(buf.cast()), size) }
    })?;
    let mut list = Vec::new();
    let mut adapter = buffer.as_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>();
    while !adapter.is_null() {
        // SAFETY: every node and address lives inside `buffer`, which outlives this loop.
        let entry = unsafe { &*adapter };
        adapter = entry.Next;
        if entry.IfType == LOOPBACK_IF_TYPE {
            continue;
        }
        let mut interface = NetInterface {
            name: wide(entry.FriendlyName),
            ..NetInterface::default()
        };
        let mac_len = (entry.PhysicalAddressLength as usize).min(entry.PhysicalAddress.len());
        if mac_len == 6 {
            let mac = &entry.PhysicalAddress[..6];
            interface.mac = Some(
                mac.iter()
                    .map(|b| format!("{b:02x}"))
                    .collect::<Vec<_>>()
                    .join(":"),
            );
        }
        let mut unicast = entry.FirstUnicastAddress;
        while !unicast.is_null() {
            // SAFETY: as above; the sockaddr matches its family.
            let address = unsafe { &*unicast };
            unicast = address.Next;
            let sockaddr = address.Address.lpSockaddr;
            if sockaddr.is_null() {
                continue;
            }
            // SAFETY: `sa_family` says which sockaddr type follows.
            unsafe {
                match (*sockaddr).sa_family {
                    AF_INET => {
                        let v4 = &*sockaddr.cast::<SOCKADDR_IN>();
                        interface.ipv4.push(
                            Ipv4Addr::from(u32::from_be(v4.sin_addr.S_un.S_addr)).to_string(),
                        );
                    }
                    AF_INET6 => {
                        let v6 = &*sockaddr.cast::<SOCKADDR_IN6>();
                        interface
                            .ipv6
                            .push(Ipv6Addr::from(v6.sin6_addr.u.Byte).to_string());
                    }
                    _ => {}
                }
            }
        }
        list.push(interface);
    }
    Ok(list)
}

/// Rows of a GetExtended*Table result: a u32 count followed by the rows.
fn rows<T: Copy>(buffer: &[u64]) -> Vec<T> {
    let base = buffer.as_ptr().cast::<u8>();
    // SAFETY: the table starts with its row count; the rows follow at the struct's alignment (≤ 8), all inside
    // the buffer the API filled.
    unsafe {
        let count = *base.cast::<u32>() as usize;
        let first = base.add(std::mem::align_of::<T>().max(4)).cast::<T>();
        let capacity =
            (buffer.len() * 8 - std::mem::align_of::<T>().max(4)) / std::mem::size_of::<T>();
        std::slice::from_raw_parts(first, count.min(capacity)).to_vec()
    }
}

fn process_name(pid: u32, cache: &mut HashMap<u32, Option<String>>) -> Option<String> {
    cache
        .entry(pid)
        .or_insert_with(|| {
            // SAFETY: plain handle calls; the handle is closed before returning.
            unsafe {
                let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
                let mut name = [0u16; 512];
                let mut len = name.len() as u32;
                let ok = QueryFullProcessImageNameW(
                    handle,
                    PROCESS_NAME_WIN32,
                    PWSTR(name.as_mut_ptr()),
                    &mut len,
                );
                let _ = CloseHandle(handle);
                ok.ok()?;
                let path = String::from_utf16_lossy(&name[..len as usize]);
                path.rsplit('\\').next().map(str::to_owned)
            }
        })
        .clone()
}

fn port(raw: u32) -> u16 {
    u16::from_be((raw & 0xffff) as u16)
}

pub fn listening_ports() -> std::io::Result<Vec<ListeningPort>> {
    let mut names = HashMap::new();
    let mut ports = Vec::new();
    let tcp = |family| {
        sized_call(|buf, size| {
            // SAFETY: `buf` holds `size` bytes.
            unsafe {
                GetExtendedTcpTable(
                    Some(buf.cast()),
                    size,
                    false,
                    u32::from(family),
                    TCP_TABLE_OWNER_PID_LISTENER,
                    0,
                )
            }
        })
    };
    let udp = |family| {
        sized_call(|buf, size| {
            // SAFETY: `buf` holds `size` bytes.
            unsafe {
                GetExtendedUdpTable(
                    Some(buf.cast()),
                    size,
                    false,
                    u32::from(family),
                    UDP_TABLE_OWNER_PID,
                    0,
                )
            }
        })
    };
    for row in rows::<MIB_TCPROW_OWNER_PID>(&tcp(AF_INET.0)?) {
        let address = Ipv4Addr::from(u32::from_be(row.dwLocalAddr)).to_string();
        let process = process_name(row.dwOwningPid, &mut names);
        ports.push(ListeningPort {
            proto: PortProto::Tcp,
            address,
            port: port(row.dwLocalPort),
            process,
        });
    }
    for row in rows::<MIB_TCP6ROW_OWNER_PID>(&tcp(AF_INET6.0)?) {
        let address = Ipv6Addr::from(row.ucLocalAddr).to_string();
        let process = process_name(row.dwOwningPid, &mut names);
        ports.push(ListeningPort {
            proto: PortProto::Tcp,
            address,
            port: port(row.dwLocalPort),
            process,
        });
    }
    for row in rows::<MIB_UDPROW_OWNER_PID>(&udp(AF_INET.0)?) {
        let address = Ipv4Addr::from(u32::from_be(row.dwLocalAddr)).to_string();
        let process = process_name(row.dwOwningPid, &mut names);
        ports.push(ListeningPort {
            proto: PortProto::Udp,
            address,
            port: port(row.dwLocalPort),
            process,
        });
    }
    for row in rows::<MIB_UDP6ROW_OWNER_PID>(&udp(AF_INET6.0)?) {
        let address = Ipv6Addr::from(row.ucLocalAddr).to_string();
        let process = process_name(row.dwOwningPid, &mut names);
        ports.push(ListeningPort {
            proto: PortProto::Udp,
            address,
            port: port(row.dwLocalPort),
            process,
        });
    }
    Ok(ports)
}
