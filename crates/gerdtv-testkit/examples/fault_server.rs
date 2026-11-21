//! Runs the fault server by hand for debugging: `cargo run -p gerdtv-testkit --example fault_server`,
//! then e.g. `mpv <printed url>/live/x.ts` or `mpv <printed url>/live/x.m3u8`. Stops with Ctrl+C.
#[tokio::main]
async fn main() {
    let srv = gerdtv_testkit::fault::FaultServer::start().await;
    println!("{}", srv.url(""));
    tokio::signal::ctrl_c().await.ok();
}
