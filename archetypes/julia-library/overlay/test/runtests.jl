# {{PROJECT_NAME}} — test entry point (julia-library archetype)
#
# Two suites, in this order:
#   1. Aqua package-shape gate — runs FIRST: a package that does not load
#      cleanly, whose deps are not compat-closed, or whose exports are
#      ambiguous is rejected before any behaviour test can pass.
#   2. Behaviour — every test/cases/*.jl is included. The shipped case
#      (smoke.jl) is a LOAD check only; replace/extend it as real
#      behaviour tests land. Until then, `Pkg.test()` passing is necessary
#      but NOT sufficient — record that in docs/status/ROADMAP.adoc (smoke-only suite).

using Test
using {{PROJECT_NAME}}

@testset "{{PROJECT_NAME}} — Aqua package shape" begin
    using Aqua
    Aqua.test_all({{PROJECT_NAME}})
end

@testset "{{PROJECT_NAME}} — behaviour" begin
    # NOTE: no `continue`/`break` inside a `for` inside @testset — Test's
    # loop-form detection re-parses the loop body at top level, where
    # `continue` is a ParseError. Filter with a guarded call instead.
    # (Measured trap, 2026-09-19 — see the Julia testing guide.)
    cases = joinpath(@__DIR__, "cases")
    if isdir(cases)
        for path in sort(readdir(cases, join = true))
            endswith(path, ".jl") && include(path)
        end
    end
end
