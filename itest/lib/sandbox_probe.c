// What sandboxed QEMU's libraries see of the Mac (itest/scenarios/qemu-sandbox.sh): the name servers slirp's DNS
// proxy (10.0.2.3) forwards to, read with res_ninit exactly as libslirp does, and whether glib's iconv conversion
// of error messages can open. Prints "ns <address>" per IPv4 server, then "iconv ok" or "iconv <error>".
#include <arpa/inet.h>
#include <errno.h>
#include <iconv.h>
#include <resolv.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    struct __res_state state;
    memset(&state, 0, sizeof state);
    if (res_ninit(&state) != 0) {
        printf("res_ninit failed\n");
    } else {
        for (int i = 0; i < state.nscount; i++) {
            char address[INET_ADDRSTRLEN];
            if (state.nsaddr_list[i].sin_family == AF_INET &&
                inet_ntop(AF_INET, &state.nsaddr_list[i].sin_addr, address, sizeof address))
                printf("ns %s\n", address);
        }
        res_ndestroy(&state);
    }
    iconv_t conversion = iconv_open("UTF-8", "US-ASCII");
    if (conversion == (iconv_t)-1) {
        printf("iconv %s\n", strerror(errno));
    } else {
        iconv_close(conversion);
        printf("iconv ok\n");
    }
    return 0;
}
