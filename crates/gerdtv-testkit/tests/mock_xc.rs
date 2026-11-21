//! Owns: the mock Xtream Codes panel answers like a real one (auth, account, categories, lists, info, M3U,
//! XMLTV, stream redirects, expiry).
use gerdtv_testkit::http::get;
use gerdtv_testkit::mock_xc::{MockXc, PASS, USER};
use serde_json::Value;

async fn api(xc: &MockXc, query: &str) -> Value {
    let (status, _, body) = get(&format!(
        "{}/player_api.php?username={USER}&password={PASS}{query}",
        xc.base()
    ))
    .await;
    assert_eq!(status, 200);
    serde_json::from_slice(&body).unwrap()
}

#[tokio::test]
async fn panel_answers_like_xtream_codes() {
    let xc = MockXc::start(3000, 3).await;

    let (_, _, body) = get(&format!(
        "{}/player_api.php?username=x&password=y",
        xc.base()
    ))
    .await;
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["user_info"]["auth"],
        0
    );

    let account = api(&xc, "").await;
    assert_eq!(account["user_info"]["max_connections"], "2");
    assert_eq!(account["user_info"]["status"], "Active");

    let cats = api(&xc, "&action=get_live_categories").await;
    let first = cats[0]["category_id"].as_str().unwrap().to_string();
    let all = api(&xc, "&action=get_live_streams").await;
    let one = api(
        &xc,
        &format!("&action=get_live_streams&category_id={first}"),
    )
    .await;
    assert_eq!(all.as_array().unwrap().len(), 900);
    assert!(!one.as_array().unwrap().is_empty() && one.as_array().unwrap().len() < 900);
    assert!(
        all.as_array()
            .unwrap()
            .iter()
            .any(|s| s["epg_channel_id"].is_null()),
        "null epg ids occur"
    );

    let vod = api(&xc, "&action=get_vod_streams").await;
    let id = vod[0]["stream_id"].as_u64().unwrap();
    assert_eq!(
        api(&xc, &format!("&action=get_vod_info&vod_id={id}")).await["movie_data"]["stream_id"],
        id
    );
    assert_eq!(
        api(&xc, "&action=get_vod_info&vod_id=1").await,
        Value::Array(vec![])
    );

    let series = api(&xc, "&action=get_series").await;
    let sid = series[0]["series_id"].as_u64().unwrap();
    let info = api(&xc, &format!("&action=get_series_info&series_id={sid}")).await;
    assert!(
        info["episodes"]
            .as_object()
            .unwrap()
            .values()
            .all(|s| s.as_array().is_some_and(|e| !e.is_empty()))
    );

    let (status, _, m3u) = get(&format!(
        "{}/get.php?username={USER}&password={PASS}&type=m3u_plus",
        xc.base()
    ))
    .await;
    assert_eq!(status, 200);
    assert_eq!(
        String::from_utf8_lossy(&m3u).matches("#EXTINF:-1").count(),
        3000
    );
    let (status, _, guide) = get(&format!(
        "{}/xmltv.php?username={USER}&password={PASS}",
        xc.base()
    ))
    .await;
    assert!(status == 200 && String::from_utf8_lossy(&guide).contains("<programme"));

    // Streams redirect to the streaming node; an expired account is refused.
    let (status, head, _) = get(&format!("{}/live/{USER}/{PASS}/100000.ts", xc.base())).await;
    assert!(status == 302 && head.contains("/live/100000.ts"));
    xc.set_expired(true);
    assert_eq!(api(&xc, "").await["user_info"]["status"], "Expired");
    assert_eq!(
        get(&format!("{}/live/{USER}/{PASS}/100000.ts", xc.base()))
            .await
            .0,
        403
    );
}
