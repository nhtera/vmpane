//! `power.shutdown`: answered first, then the guest shuts down or reboots.

use std::time::Duration;

use vmpane_agent_proto::jsonrpc::ErrorObject;
use vmpane_agent_proto::methods::{Empty, PowerShutdownParams};

use crate::connection::Reply;

pub fn shutdown(params: PowerShutdownParams) -> Result<Reply, ErrorObject> {
    Reply::then(&Empty {}, async move {
        // Let the response leave before the system starts going down.
        tokio::time::sleep(Duration::from_millis(500)).await;
        let (program, args) = crate::os::shutdown_command(params.reboot, params.force);
        tracing::info!(
            reboot = params.reboot,
            force = params.force,
            "shutting down at the host's request"
        );
        if let Err(err) = tokio::process::Command::new(program)
            .args(args)
            .status()
            .await
        {
            tracing::error!(%err, "shutdown command failed");
        }
    })
}
