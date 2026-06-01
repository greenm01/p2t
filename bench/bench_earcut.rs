use std::f64::consts::PI;
use std::fs;
use std::time::Instant;

use earcut::Earcut;

const BENCH_ROUNDS: usize = 5;

struct BenchCase {
    name: &'static str,
    iterations: usize,
    data: Vec<[f64; 2]>,
    holes: Vec<u32>,
}

fn regular_polygon(n: usize, radius: f64) -> Vec<[f64; 2]> {
    (0..n)
        .map(|i| {
            let angle = 2.0 * PI * i as f64 / n as f64;
            [angle.cos() * radius, angle.sin() * radius]
        })
        .collect()
}

fn read_dat(name: &str) -> Vec<[f64; 2]> {
    let path = format!("tests/fixtures/{name}");
    fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {path}: {err}"))
        .lines()
        .filter_map(|line| {
            let mut parts = line.split_whitespace();
            let x = parts.next()?.parse::<f64>().ok()?;
            let y = parts.next()?.parse::<f64>().ok()?;
            Some([x, y])
        })
        .collect()
}

fn with_holes(outer: Vec<[f64; 2]>, holes: &[&[[f64; 2]]]) -> (Vec<[f64; 2]>, Vec<u32>) {
    let mut data = outer;
    let mut hole_indices = Vec::with_capacity(holes.len());
    for hole in holes {
        hole_indices.push(data.len() as u32);
        data.extend_from_slice(hole);
    }
    (data, hole_indices)
}

fn bench_case(case: &BenchCase) {
    let mut times = [0u128; BENCH_ROUNDS];
    let mut reported_triangles = 0usize;
    let mut earcut = Earcut::<f64>::new();
    let mut triangles: Vec<u32> = Vec::new();

    for time in &mut times {
        let mut triangle_count = 0usize;
        let start = Instant::now();
        for _ in 0..case.iterations {
            earcut.earcut(case.data.iter().copied(), &case.holes, &mut triangles);
            triangle_count += triangles.len() / 3;
        }
        *time = start.elapsed().as_micros();
        reported_triangles = triangle_count;
    }

    times.sort_unstable();
    println!(
        "{}: {} runs, {} triangles, best {} us, median {} us",
        case.name,
        case.iterations,
        reported_triangles,
        times[0],
        times[BENCH_ROUNDS / 2]
    );
}

fn main() {
    let head_hole = [
        [325.0, 437.0],
        [320.0, 423.0],
        [329.0, 413.0],
        [332.0, 423.0],
    ];
    let chest_hole = [
        [320.72342, 480.0],
        [338.90617, 465.96863],
        [347.99754, 480.61584],
        [329.8148, 510.41534],
        [339.91632, 480.11077],
        [334.86556, 478.09046],
    ];
    let (dude_data, dude_holes) = with_holes(read_dat("dude.dat"), &[&head_hole, &chest_hole]);

    let cases = [
        BenchCase {
            name: "small-ui-quad",
            iterations: 10000,
            data: vec![[0.0, 0.0], [100.0, 0.0], [100.0, 40.0], [0.0, 40.0]],
            holes: Vec::new(),
        },
        BenchCase {
            name: "medium-icon",
            iterations: 2000,
            data: regular_polygon(48, 50.0),
            holes: Vec::new(),
        },
        BenchCase {
            name: "large-shape",
            iterations: 500,
            data: regular_polygon(512, 100.0),
            holes: Vec::new(),
        },
        BenchCase {
            name: "fixture-test",
            iterations: 10000,
            data: read_dat("test.dat"),
            holes: Vec::new(),
        },
        BenchCase {
            name: "diamond",
            iterations: 10000,
            data: read_dat("diamond.dat"),
            holes: Vec::new(),
        },
        BenchCase {
            name: "star",
            iterations: 10000,
            data: read_dat("star.dat"),
            holes: Vec::new(),
        },
        BenchCase {
            name: "dude-with-holes",
            iterations: 1000,
            data: dude_data,
            holes: dude_holes,
        },
        BenchCase {
            name: "nazca-monkey",
            iterations: 100,
            data: read_dat("nazca_monkey.dat"),
            holes: Vec::new(),
        },
        BenchCase {
            name: "nazca-heron",
            iterations: 100,
            data: read_dat("nazca_heron.dat"),
            holes: Vec::new(),
        },
    ];

    println!("earcut f64");
    for case in &cases {
        bench_case(case);
    }
}
