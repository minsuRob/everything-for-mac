// Benchmarks Cardinal's own search engine (search-cache crate) on a directory tree.
// usage: cardbench ROOT [--case] [--repeat N] QUERY...
use search_cache::{SearchCache, SearchOptions};
use search_cancel::CancellationToken;
use std::path::Path;
use std::time::Instant;

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let root = args.remove(0);
    let mut case_insensitive = true;
    let mut repeat = 5usize;
    let mut queries = vec![];
    while !args.is_empty() {
        let a = args.remove(0);
        match a.as_str() {
            "--case" => case_insensitive = false,
            "--repeat" => repeat = args.remove(0).parse().unwrap(),
            _ => queries.push(a),
        }
    }
    let t = Instant::now();
    let mut cache = SearchCache::walk_fs(Path::new(&root));
    println!("index ready: {} entries in {:.2}s", cache.get_total_files(), t.elapsed().as_secs_f64());
    println!("query\tresults\tfirst_ms\tmedian_ms\tmin_ms");
    for q in queries {
        let mut times = vec![];
        let mut n = 0;
        let mut ok = true;
        for _ in 0..repeat {
            let t = Instant::now();
            match cache.search_with_options(&q, SearchOptions { case_insensitive }, CancellationToken::noop()) {
                Ok(out) => {
                    n = out.nodes.map(|v| v.len()).unwrap_or(0);
                    times.push(t.elapsed().as_secs_f64() * 1000.0);
                }
                Err(e) => { println!("{q}\terror: {e}"); ok = false; break; }
            }
        }
        if !ok { continue; }
        let first = times[0];
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!("{q}\t{n}\t{first:.2}\t{:.2}\t{:.2}", times[times.len() / 2], times[0]);
    }
}
