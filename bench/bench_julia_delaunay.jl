#!/usr/bin/env julia

using DelaunayTriangulation

const ROOT_DIR = normpath(joinpath(@__DIR__, ".."))
const FIXTURE_DIR = joinpath(ROOT_DIR, "tests", "fixtures")

function env_int(name::AbstractString, default::Int)
    value = get(ENV, name, "")
    isempty(value) && return default
    return parse(Int, value)
end

function env_float(name::AbstractString, default::Float64)
    value = get(ENV, name, "")
    isempty(value) && return default
    return parse(Float64, value)
end

const BENCH_ROUNDS = max(1, env_int("P2T_JULIA_BENCH_ROUNDS", 5))
const BENCH_SCALE = max(0.0, env_float("P2T_JULIA_BENCH_SCALE", 1.0))
const BENCH_CASES = Set(filter(!isempty, strip.(split(get(ENV, "P2T_JULIA_BENCH_CASES", ""), ","))))

function scaled_iterations(iterations::Int)
    return max(1, round(Int, iterations * BENCH_SCALE))
end

function enabled_case(name::AbstractString)
    return isempty(BENCH_CASES) || name in BENCH_CASES
end

function regular_polygon(n::Int, radius::Float64)
    return [(cos(2.0 * pi * (i - 1) / n) * radius, sin(2.0 * pi * (i - 1) / n) * radius) for i in 1:n]
end

function read_dat(name::AbstractString)
    points = Tuple{Float64,Float64}[]
    open(joinpath(FIXTURE_DIR, name), "r") do io
        for line in eachline(io)
            stripped = strip(line)
            isempty(stripped) && break
            parts = split(stripped)
            push!(points, (parse(Float64, parts[1]), parse(Float64, parts[2])))
        end
    end
    return points
end

function signed_area(points)
    area = 0.0
    n = length(points)
    for i in 1:n
        p = points[i]
        q = points[i == n ? 1 : i + 1]
        area += p[1] * q[2] - q[1] * p[2]
    end
    return area / 2.0
end

function oriented(points; ccw::Bool)
    is_ccw = signed_area(points) > 0.0
    return is_ccw == ccw ? copy(points) : reverse(points)
end

function closed(points)
    result = copy(points)
    push!(result, first(result))
    return result
end

function boundary_input(outer; holes = Vector{Tuple{Float64,Float64}}[])
    curves = Vector{Vector{Vector{Tuple{Float64,Float64}}}}()
    push!(curves, [closed(oriented(outer; ccw = true))])
    for hole in holes
        push!(curves, [closed(oriented(hole; ccw = false))])
    end

    points = Tuple{Float64,Float64}[]
    boundary_nodes, points = convert_boundary_points_to_indices(curves; existing_points = points)
    return points, boundary_nodes
end

function triangulate_case(points, boundary_nodes)
    tri = triangulate(points; boundary_nodes)
    return num_solid_triangles(tri)
end

function bench_case(name::AbstractString, iterations::Int, points, boundary_nodes)
    enabled_case(name) || return
    iterations = scaled_iterations(iterations)
    triangulate_case(points, boundary_nodes)

    times = Vector{Int64}(undef, BENCH_ROUNDS)
    reported_triangles = 0
    for round in 1:BENCH_ROUNDS
        triangles = 0
        start = time_ns()
        for _ in 1:iterations
            triangles += triangulate_case(points, boundary_nodes)
        end
        times[round] = Int64((time_ns() - start) ÷ 1000)
        reported_triangles = triangles
    end

    sort!(times)
    println("$name: $iterations runs, $reported_triangles triangles, best $(times[1]) us, median $(times[(BENCH_ROUNDS ÷ 2) + 1]) us")
end

function run_case(name::AbstractString, iterations::Int, outer; holes = Vector{Tuple{Float64,Float64}}[])
    points, boundary_nodes = boundary_input(outer; holes)
    bench_case(name, iterations, points, boundary_nodes)
end

function main()
    println("julia-delaunay")
    run_case("small-ui-quad", 10000, [(0.0, 0.0), (100.0, 0.0), (100.0, 40.0), (0.0, 40.0)])
    run_case("medium-icon", 2000, regular_polygon(48, 50.0))
    run_case("large-shape", 500, regular_polygon(512, 100.0))
    run_case("fixture-test", 10000, read_dat("test.dat"))
    run_case("diamond", 10000, read_dat("diamond.dat"))
    run_case("star", 10000, read_dat("star.dat"))
    run_case(
        "dude-with-holes",
        1000,
        read_dat("dude.dat");
        holes = [
            [(325.0, 437.0), (320.0, 423.0), (329.0, 413.0), (332.0, 423.0)],
            [
                (320.72342, 480.0),
                (338.90617, 465.96863),
                (347.99754, 480.61584),
                (329.8148, 510.41534),
                (339.91632, 480.11077),
                (334.86556, 478.09046),
            ],
        ],
    )
    run_case("nazca-monkey", 100, read_dat("nazca_monkey.dat"))
    run_case("nazca-heron", 100, read_dat("nazca_heron.dat"))
end

main()
