//! Runs the mock Xtream Codes panel by hand or for the app's integration tests:
//! `cargo run -p gerdtv-testkit --example mock_xc` prints the panel URL (login testuser / testpass).
#[tokio::main]
async fn main() {
    let xc = gerdtv_testkit::mock_xc::MockXc::start(3000, 7).await;
    println!("{}", xc.base());
    tokio::signal::ctrl_c().await.ok();
}
