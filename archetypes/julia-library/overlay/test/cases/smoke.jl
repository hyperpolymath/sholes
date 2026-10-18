# smoke.jl — the archetype's load-check case.
#
# This case proves the package LOADS (module resolution, no parse/load
# errors, top-level evaluation clean). It is deliberately not a behaviour
# test: a repo whose only case is this file has a NECESSARY-but-not-
# sufficient green. Replace it with real behaviour tests as they land —
# do not delete it (the Aqua suite already covers shape; this covers load).

@testset "smoke — package loads" begin
    @test @isdefined {{PROJECT_NAME}}
end
