//! Owns: the mock TMDB answers searches, details, seasons, bad keys and 429 like the real API.
use gerdtv_testkit::http::get;
use gerdtv_testkit::mock_tmdb::{KEY, MockTmdb};
use serde_json::Value;

async fn json(url: &str) -> (u16, Value) {
    let (status, _, body) = get(url).await;
    (status, serde_json::from_slice(&body).unwrap())
}

#[tokio::test]
async fn tmdb_mock_answers_like_tmdb() {
    let t = MockTmdb::start().await;
    let b = t.base();
    // Umlaut-folded search; the year picks one of two films with the same title; tv vs movie stay apart.
    let (s, v) = json(&format!(
        "{b}/3/search/movie?api_key={KEY}&query=reise%20nach%20munchen"
    ))
    .await;
    assert_eq!((s, v["total_results"].as_u64()), (200, Some(2)));
    let (_, v) = json(&format!(
        "{b}/3/search/movie?api_key={KEY}&query=reise%20nach%20munchen&year=1972"
    ))
    .await;
    assert_eq!(v["results"][0]["id"], 1002);
    let (_, v) = json(&format!(
        "{b}/3/search/tv?api_key={KEY}&query=planet%20wissen"
    ))
    .await;
    assert_eq!(
        (v["total_results"].as_u64(), &v["results"][0]["id"]),
        (Some(1), &Value::from(2001))
    );
    let (_, v) = json(&format!(
        "{b}/3/search/movie?api_key={KEY}&query=nothing%20like%20this"
    ))
    .await;
    assert_eq!(v["total_results"], 0);

    let (_, v) = json(&format!(
        "{b}/3/movie/1003?api_key={KEY}&append_to_response=credits,videos"
    ))
    .await;
    assert_eq!(v["credits"]["cast"].as_array().unwrap().len(), 12);
    assert_eq!(v["videos"]["results"][0]["site"], "YouTube");
    let (_, v) = json(&format!("{b}/3/tv/2002/season/1?api_key={KEY}")).await;
    assert_eq!(v["episodes"].as_array().unwrap().len(), 6);
    assert_eq!(json(&format!("{b}/3/movie/9?api_key={KEY}")).await.0, 404);
    assert_eq!(
        json(&format!("{b}/3/movie/1001?api_key=wrong")).await.0,
        401
    );

    t.rate_limit(2);
    let (s1, head, _) = get(&format!("{b}/3/movie/1001?api_key={KEY}")).await;
    assert!(s1 == 429 && head.contains("Retry-After: 1"));
    assert_eq!(get(&format!("{b}/3/movie/1001?api_key={KEY}")).await.0, 429);
    assert_eq!(get(&format!("{b}/3/movie/1001?api_key={KEY}")).await.0, 200);
    assert_eq!(
        t.requests(),
        11,
        "every request is counted, throttled ones too"
    );
}
