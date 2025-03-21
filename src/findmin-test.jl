### A Pluto.jl notebook ###
# v0.20.4

using Markdown
using InteractiveUtils

# ╔═╡ 7b374f71-3e15-40a6-b2a4-c52604df6b11
using BenchmarkTools

# ╔═╡ 061c9416-9df3-4627-beb7-51d5316ca3f1
using Chairmarks

# ╔═╡ d1c1bf06-1ce8-4b22-bffd-6d60790d1a82
using LoopVectorization

# ╔═╡ a960351a-3bb1-11ef-2feb-2363fb988b65
md"# Find Minimum - Speed test

Benchmark the speed of finding the minimum value in an array, where the array is shrunk by 1 for each subsequent iteration. This is a proxy for the [jet reconstruction](https://github.com/JuliaHEP/JetReconstruction.jl) case, where the number of active jets descreases as the reconstruction proceeds.

Also test the speed of minimum finding on a fixed array size.
"

# ╔═╡ 9898de08-488d-4947-aff8-c99272efe3b3
Base.VERSION

# ╔═╡ 13ae413a-4726-4406-a634-aabd6b24a9ad
array_size = 500

# ╔═╡ 18eb6dde-ef55-4e0a-9dac-aeb980dd4dba
x = rand(array_size);

# ╔═╡ c06113a9-0cad-4ccb-bcd3-e4fd34e02c24
fast_findmin(dij, n) = begin
    best = 1
    @inbounds dij_min = dij[1]
    @turbo for here in 2:n
        newmin = dij[here] < dij_min
        best = newmin ? here : best
        dij_min = newmin ? dij[here] : dij_min
    end
    dij_min, best
end

# ╔═╡ cc518f06-053c-4baf-ac39-bb8e617ee0bd
md"## Shrinking Array Test"

# ╔═╡ 3d56ff60-2e77-4943-8659-aa14b69f6908
md"### Julia `findmin`"

# ╔═╡ 0143579d-3dad-43ff-b504-9af0a50fa660
@b for j in array_size:-1:1
    findmin(@view x[1:j])
end

# ╔═╡ a83cd7a2-7045-4ba2-b8f2-4a001abf7789
md"### Fast `findmin` (vectorised)"

# ╔═╡ 3e96d66a-f0ac-4c27-8247-962957ed9d23
@b for j in array_size:-1:1
    fast_findmin(x, j)
end

# ╔═╡ 13874a32-7acd-4b70-86cb-97106b0f8ba5
md"## Fixed Array Size Test"

# ╔═╡ 8275656a-4d27-4f17-8abf-df006d45e8f9
md"### Julia `findmin`"

# ╔═╡ 55255948-5e85-441e-adc4-f4f46f343215
@be findmin(x)

# ╔═╡ d6fa4369-deb8-44fa-8dcc-03711a1c3118
md"### Fast `findmin`"

# ╔═╡ 02cdaaf1-966f-4d63-bdbb-75a437b46e30
@be fast_findmin(x, array_size)

# ╔═╡ 3635389e-1ee1-4e39-9836-66cc098ecc44
function naive_findmin(w)
    x = @fastmath foldl(min, w)
    i = findfirst(==(x), w)::Int
    x, i
end

# ╔═╡ 708cf089-9051-45de-84de-92b0cb2556c8
@be naive_findmin(x)

# ╔═╡ 496dd7f5-2669-4d5e-8f75-cefb33931ba6
@code_llvm fast_findmin(x, array_size)

# ╔═╡ 435ad5f2-5b50-4bf4-adb1-d3253889291c
@code_llvm findmin(x)

# ╔═╡ debf5715-18ee-4919-8585-4216924716c5
struct IVTuple
	i::Int
	value::Float64
end

# ╔═╡ 6d9bf8e4-0aea-4f1b-ac53-0bd2354aa3af
iv(v::Vector{T}, i::Int) where T = IVTuple(i, v[i])

# ╔═╡ 3a7eacb2-9b3e-4805-ad13-4e53a061ca0a
iv(x, 10)

# ╔═╡ 8ed7b364-8525-42a9-941d-c6b28f113be9
Base.:<(x::IVTuple, y::IVTuple) = x.value < y.value

# ╔═╡ 7a53ee87-d302-47ef-a5b6-f6650fefeb10
function basic_findmin(dij, n)
   best = 1
   @inbounds dij_min = dij[1]
   @inbounds @simd for here in 2:n
	   dij_here = dij[here]
	   newmin = dij_here < dij_min
	   best = ifelse(newmin, here, best)
	   dij_min = ifelse(newmin, dij_here, dij_min)
   end
   dij_min, best
end

# ╔═╡ 7567da79-9657-42c3-860a-7b8026e70ab7
@be basic_findmin(x, array_size)

# ╔═╡ 39a7f57c-bd7a-4fbd-9486-01098f198ab1
x1=iv(x, 20)

# ╔═╡ 3ccb5421-53ac-4deb-acc8-42670c740ec8
x2=iv(x,99)

# ╔═╡ 4798788e-fd6b-4a5b-9115-dc249f81c881
x1 < x2

# ╔═╡ 7d2622eb-5ee8-4763-9e87-a284f30f0c17
x2 < x1

# ╔═╡ 9d32ba80-b542-451d-8a96-4b288f6ec80d
x1 > x2

# ╔═╡ f3df4abd-7b31-491c-9833-ff4744bc0766
x1 == x2

# ╔═╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
BenchmarkTools = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
Chairmarks = "0ca39b1e-fe0b-4e98-acfc-b1656634c4de"
LoopVectorization = "bdcacae8-1622-11e9-2a5c-532679323890"

[compat]
BenchmarkTools = "~1.5.0"
Chairmarks = "~1.2.2"
LoopVectorization = "~0.12.171"
"""

# ╔═╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.11.4"
manifest_format = "2.0"
project_hash = "d8d6cba016d47c6446b96c0a081324d53213a819"

[[deps.Adapt]]
deps = ["LinearAlgebra", "Requires"]
git-tree-sha1 = "6a55b747d1812e699320963ffde36f1ebdda4099"
uuid = "79e6a3ab-5dfb-504d-930d-738a2a938a0e"
version = "4.0.4"

    [deps.Adapt.extensions]
    AdaptStaticArraysExt = "StaticArrays"

    [deps.Adapt.weakdeps]
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

[[deps.ArrayInterface]]
deps = ["Adapt", "LinearAlgebra"]
git-tree-sha1 = "3640d077b6dafd64ceb8fd5c1ec76f7ca53bcf76"
uuid = "4fba245c-0d91-5ea0-9b3e-6abc04ee57a9"
version = "7.16.0"

    [deps.ArrayInterface.extensions]
    ArrayInterfaceBandedMatricesExt = "BandedMatrices"
    ArrayInterfaceBlockBandedMatricesExt = "BlockBandedMatrices"
    ArrayInterfaceCUDAExt = "CUDA"
    ArrayInterfaceCUDSSExt = "CUDSS"
    ArrayInterfaceChainRulesExt = "ChainRules"
    ArrayInterfaceGPUArraysCoreExt = "GPUArraysCore"
    ArrayInterfaceReverseDiffExt = "ReverseDiff"
    ArrayInterfaceSparseArraysExt = "SparseArrays"
    ArrayInterfaceStaticArraysCoreExt = "StaticArraysCore"
    ArrayInterfaceTrackerExt = "Tracker"

    [deps.ArrayInterface.weakdeps]
    BandedMatrices = "aae01518-5342-5314-be14-df237901396f"
    BlockBandedMatrices = "ffab5731-97b5-5995-9138-79e8c1846df0"
    CUDA = "052768ef-5323-5732-b1bb-66c8b64840ba"
    CUDSS = "45b445bb-4962-46a0-9369-b4df9d0f772e"
    ChainRules = "082447d4-558c-5d27-93f4-14fc19e9eca2"
    GPUArraysCore = "46192b85-c4d5-4398-a991-12ede77f4527"
    ReverseDiff = "37e2e3b7-166d-5795-8a7a-e32c996b4267"
    SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
    StaticArraysCore = "1e83bf80-4336-4d27-bf5d-d5a4f845583c"
    Tracker = "9f7883ad-71c0-57eb-9f7f-b5c9e6d3789c"

[[deps.Artifacts]]
uuid = "56f22d72-fd6d-98f1-02f0-08ddc0907c33"
version = "1.11.0"

[[deps.Base64]]
uuid = "2a0f44e3-6c83-55bd-87e4-b1978d98bd5f"
version = "1.11.0"

[[deps.BenchmarkTools]]
deps = ["JSON", "Logging", "Printf", "Profile", "Statistics", "UUIDs"]
git-tree-sha1 = "f1dff6729bc61f4d49e140da1af55dcd1ac97b2f"
uuid = "6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"
version = "1.5.0"

[[deps.BitTwiddlingConvenienceFunctions]]
deps = ["Static"]
git-tree-sha1 = "f21cfd4950cb9f0587d5067e69405ad2acd27b87"
uuid = "62783981-4cbd-42fc-bca8-16325de8dc4b"
version = "0.1.6"

[[deps.CPUSummary]]
deps = ["CpuId", "IfElse", "PrecompileTools", "Static"]
git-tree-sha1 = "5a97e67919535d6841172016c9530fd69494e5ec"
uuid = "2a0fbf3d-bb9c-48f3-b0a9-814d99fd7ab9"
version = "0.2.6"

[[deps.Chairmarks]]
deps = ["Printf"]
git-tree-sha1 = "9bf9d4b0d4a1acc212251eebbdf76f2ad70aae67"
uuid = "0ca39b1e-fe0b-4e98-acfc-b1656634c4de"
version = "1.2.2"
weakdeps = ["Statistics"]

    [deps.Chairmarks.extensions]
    StatisticsChairmarksExt = ["Statistics"]

[[deps.CloseOpenIntervals]]
deps = ["Static", "StaticArrayInterface"]
git-tree-sha1 = "05ba0d07cd4fd8b7a39541e31a7b0254704ea581"
uuid = "fb6a15b2-703c-40df-9091-08a04967cfa9"
version = "0.1.13"

[[deps.CommonWorldInvalidations]]
git-tree-sha1 = "ae52d1c52048455e85a387fbee9be553ec2b68d0"
uuid = "f70d9fcc-98c5-4d4a-abd7-e4cdeebd8ca8"
version = "1.0.0"

[[deps.Compat]]
deps = ["TOML", "UUIDs"]
git-tree-sha1 = "8ae8d32e09f0dcf42a36b90d4e17f5dd2e4c4215"
uuid = "34da2185-b29b-5c13-b0c7-acf172513d20"
version = "4.16.0"
weakdeps = ["Dates", "LinearAlgebra"]

    [deps.Compat.extensions]
    CompatLinearAlgebraExt = "LinearAlgebra"

[[deps.CompilerSupportLibraries_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "e66e0078-7015-5450-92f7-15fbd957f2ae"
version = "1.1.1+0"

[[deps.CpuId]]
deps = ["Markdown"]
git-tree-sha1 = "fcbb72b032692610bfbdb15018ac16a36cf2e406"
uuid = "adafc99b-e345-5852-983c-f28acb93d879"
version = "0.3.1"

[[deps.Dates]]
deps = ["Printf"]
uuid = "ade2ca70-3891-5945-98fb-dc099432e06a"
version = "1.11.0"

[[deps.DocStringExtensions]]
deps = ["LibGit2"]
git-tree-sha1 = "2fb1e02f2b635d0845df5d7c167fec4dd739b00d"
uuid = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"
version = "0.9.3"

[[deps.HostCPUFeatures]]
deps = ["BitTwiddlingConvenienceFunctions", "IfElse", "Libdl", "Static"]
git-tree-sha1 = "8e070b599339d622e9a081d17230d74a5c473293"
uuid = "3e5b6fbb-0976-4d2c-9146-d79de83f2fb0"
version = "0.1.17"

[[deps.IfElse]]
git-tree-sha1 = "debdd00ffef04665ccbb3e150747a77560e8fad1"
uuid = "615f187c-cbe4-4ef1-ba3b-2fcf58d6d173"
version = "0.1.1"

[[deps.JSON]]
deps = ["Dates", "Mmap", "Parsers", "Unicode"]
git-tree-sha1 = "31e996f0a15c7b280ba9f76636b3ff9e2ae58c9a"
uuid = "682c06a0-de6a-54ab-a142-c8b1cf79cde6"
version = "0.21.4"

[[deps.LayoutPointers]]
deps = ["ArrayInterface", "LinearAlgebra", "ManualMemory", "SIMDTypes", "Static", "StaticArrayInterface"]
git-tree-sha1 = "a9eaadb366f5493a5654e843864c13d8b107548c"
uuid = "10f19ff3-798f-405d-979b-55457f8fc047"
version = "0.1.17"

[[deps.LibGit2]]
deps = ["Base64", "LibGit2_jll", "NetworkOptions", "Printf", "SHA"]
uuid = "76f85450-5226-5b5a-8eaa-529ad045b433"
version = "1.11.0"

[[deps.LibGit2_jll]]
deps = ["Artifacts", "LibSSH2_jll", "Libdl", "MbedTLS_jll"]
uuid = "e37daf67-58a4-590a-8e99-b0245dd2ffc5"
version = "1.7.2+0"

[[deps.LibSSH2_jll]]
deps = ["Artifacts", "Libdl", "MbedTLS_jll"]
uuid = "29816b5a-b9ab-546f-933c-edad1886dfa8"
version = "1.11.0+1"

[[deps.Libdl]]
uuid = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
version = "1.11.0"

[[deps.LinearAlgebra]]
deps = ["Libdl", "OpenBLAS_jll", "libblastrampoline_jll"]
uuid = "37e2e46d-f89d-539d-b4ee-838fcccc9c8e"
version = "1.11.0"

[[deps.Logging]]
uuid = "56ddb016-857b-54e1-b83d-db4d58db5568"
version = "1.11.0"

[[deps.LoopVectorization]]
deps = ["ArrayInterface", "CPUSummary", "CloseOpenIntervals", "DocStringExtensions", "HostCPUFeatures", "IfElse", "LayoutPointers", "LinearAlgebra", "OffsetArrays", "PolyesterWeave", "PrecompileTools", "SIMDTypes", "SLEEFPirates", "Static", "StaticArrayInterface", "ThreadingUtilities", "UnPack", "VectorizationBase"]
git-tree-sha1 = "8084c25a250e00ae427a379a5b607e7aed96a2dd"
uuid = "bdcacae8-1622-11e9-2a5c-532679323890"
version = "0.12.171"

    [deps.LoopVectorization.extensions]
    ForwardDiffExt = ["ChainRulesCore", "ForwardDiff"]
    SpecialFunctionsExt = "SpecialFunctions"

    [deps.LoopVectorization.weakdeps]
    ChainRulesCore = "d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4"
    ForwardDiff = "f6369f11-7733-5829-9624-2563aa707210"
    SpecialFunctions = "276daf66-3868-5448-9aa4-cd146d93841b"

[[deps.ManualMemory]]
git-tree-sha1 = "bcaef4fc7a0cfe2cba636d84cda54b5e4e4ca3cd"
uuid = "d125e4d3-2237-4719-b19c-fa641b8a4667"
version = "0.1.8"

[[deps.Markdown]]
deps = ["Base64"]
uuid = "d6f4376e-aef5-505a-96c1-9c027394607a"
version = "1.11.0"

[[deps.MbedTLS_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "c8ffd9c3-330d-5841-b78e-0817d7145fa1"
version = "2.28.6+0"

[[deps.Mmap]]
uuid = "a63ad114-7e13-5084-954f-fe012c677804"
version = "1.11.0"

[[deps.NetworkOptions]]
uuid = "ca575930-c2e3-43a9-ace4-1e988b2c1908"
version = "1.2.0"

[[deps.OffsetArrays]]
git-tree-sha1 = "1a27764e945a152f7ca7efa04de513d473e9542e"
uuid = "6fe1bfb0-de20-5000-8ca7-80f57d26f881"
version = "1.14.1"
weakdeps = ["Adapt"]

    [deps.OffsetArrays.extensions]
    OffsetArraysAdaptExt = "Adapt"

[[deps.OpenBLAS_jll]]
deps = ["Artifacts", "CompilerSupportLibraries_jll", "Libdl"]
uuid = "4536629a-c528-5b80-bd46-f80d51c5b363"
version = "0.3.27+1"

[[deps.Parsers]]
deps = ["Dates", "PrecompileTools", "UUIDs"]
git-tree-sha1 = "8489905bcdbcfac64d1daa51ca07c0d8f0283821"
uuid = "69de0a69-1ddd-5017-9359-2bf0b02dc9f0"
version = "2.8.1"

[[deps.PolyesterWeave]]
deps = ["BitTwiddlingConvenienceFunctions", "CPUSummary", "IfElse", "Static", "ThreadingUtilities"]
git-tree-sha1 = "645bed98cd47f72f67316fd42fc47dee771aefcd"
uuid = "1d0040c9-8b98-4ee7-8388-3f51789ca0ad"
version = "0.2.2"

[[deps.PrecompileTools]]
deps = ["Preferences"]
git-tree-sha1 = "5aa36f7049a63a1528fe8f7c3f2113413ffd4e1f"
uuid = "aea7be01-6a6a-4083-8856-8a6e6704d82a"
version = "1.2.1"

[[deps.Preferences]]
deps = ["TOML"]
git-tree-sha1 = "9306f6085165d270f7e3db02af26a400d580f5c6"
uuid = "21216c6a-2e73-6563-6e65-726566657250"
version = "1.4.3"

[[deps.Printf]]
deps = ["Unicode"]
uuid = "de0858da-6303-5e67-8744-51eddeeeb8d7"
version = "1.11.0"

[[deps.Profile]]
uuid = "9abbd945-dff8-562f-b5e8-e1ebf5ef1b79"
version = "1.11.0"

[[deps.Random]]
deps = ["SHA"]
uuid = "9a3f8284-a2c9-5f02-9a11-845980a1fd5c"
version = "1.11.0"

[[deps.Requires]]
deps = ["UUIDs"]
git-tree-sha1 = "838a3a4188e2ded87a4f9f184b4b0d78a1e91cb7"
uuid = "ae029012-a4dd-5104-9daa-d747884805df"
version = "1.3.0"

[[deps.SHA]]
uuid = "ea8e919c-243c-51af-8825-aaa63cd721ce"
version = "0.7.0"

[[deps.SIMDTypes]]
git-tree-sha1 = "330289636fb8107c5f32088d2741e9fd7a061a5c"
uuid = "94e857df-77ce-4151-89e5-788b33177be4"
version = "0.1.0"

[[deps.SLEEFPirates]]
deps = ["IfElse", "Static", "VectorizationBase"]
git-tree-sha1 = "456f610ca2fbd1c14f5fcf31c6bfadc55e7d66e0"
uuid = "476501e8-09a2-5ece-8869-fb82de89a1fa"
version = "0.6.43"

[[deps.Static]]
deps = ["CommonWorldInvalidations", "IfElse", "PrecompileTools"]
git-tree-sha1 = "87d51a3ee9a4b0d2fe054bdd3fc2436258db2603"
uuid = "aedffcd0-7271-4cad-89d0-dc628f76c6d3"
version = "1.1.1"

[[deps.StaticArrayInterface]]
deps = ["ArrayInterface", "Compat", "IfElse", "LinearAlgebra", "PrecompileTools", "Static"]
git-tree-sha1 = "96381d50f1ce85f2663584c8e886a6ca97e60554"
uuid = "0d7ed370-da01-4f52-bd93-41d350b8b718"
version = "1.8.0"

    [deps.StaticArrayInterface.extensions]
    StaticArrayInterfaceOffsetArraysExt = "OffsetArrays"
    StaticArrayInterfaceStaticArraysExt = "StaticArrays"

    [deps.StaticArrayInterface.weakdeps]
    OffsetArrays = "6fe1bfb0-de20-5000-8ca7-80f57d26f881"
    StaticArrays = "90137ffa-7385-5640-81b9-e52037218182"

[[deps.Statistics]]
deps = ["LinearAlgebra"]
git-tree-sha1 = "ae3bb1eb3bba077cd276bc5cfc337cc65c3075c0"
uuid = "10745b16-79ce-11e8-11f9-7d13ad32a3b2"
version = "1.11.1"

    [deps.Statistics.extensions]
    SparseArraysExt = ["SparseArrays"]

    [deps.Statistics.weakdeps]
    SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"

[[deps.TOML]]
deps = ["Dates"]
uuid = "fa267f1f-6049-4f14-aa54-33bafae1ed76"
version = "1.0.3"

[[deps.ThreadingUtilities]]
deps = ["ManualMemory"]
git-tree-sha1 = "eda08f7e9818eb53661b3deb74e3159460dfbc27"
uuid = "8290d209-cae3-49c0-8002-c8c24d57dab5"
version = "0.5.2"

[[deps.UUIDs]]
deps = ["Random", "SHA"]
uuid = "cf7118a7-6976-5b1a-9a39-7adc72f591a4"
version = "1.11.0"

[[deps.UnPack]]
git-tree-sha1 = "387c1f73762231e86e0c9c5443ce3b4a0a9a0c2b"
uuid = "3a884ed6-31ef-47d7-9d2a-63182c4928ed"
version = "1.0.2"

[[deps.Unicode]]
uuid = "4ec0a83e-493e-50e2-b9ac-8f72acf5a8f5"
version = "1.11.0"

[[deps.VectorizationBase]]
deps = ["ArrayInterface", "CPUSummary", "HostCPUFeatures", "IfElse", "LayoutPointers", "Libdl", "LinearAlgebra", "SIMDTypes", "Static", "StaticArrayInterface"]
git-tree-sha1 = "e7f5b81c65eb858bed630fe006837b935518aca5"
uuid = "3d5dd08c-fd9d-11e8-17fa-ed2836048c2f"
version = "0.21.70"

[[deps.libblastrampoline_jll]]
deps = ["Artifacts", "Libdl"]
uuid = "8e850b90-86db-534c-a0d3-1478176c7d93"
version = "5.11.0+0"
"""

# ╔═╡ Cell order:
# ╟─a960351a-3bb1-11ef-2feb-2363fb988b65
# ╠═9898de08-488d-4947-aff8-c99272efe3b3
# ╠═7b374f71-3e15-40a6-b2a4-c52604df6b11
# ╠═061c9416-9df3-4627-beb7-51d5316ca3f1
# ╠═d1c1bf06-1ce8-4b22-bffd-6d60790d1a82
# ╠═13ae413a-4726-4406-a634-aabd6b24a9ad
# ╠═18eb6dde-ef55-4e0a-9dac-aeb980dd4dba
# ╠═c06113a9-0cad-4ccb-bcd3-e4fd34e02c24
# ╟─cc518f06-053c-4baf-ac39-bb8e617ee0bd
# ╟─3d56ff60-2e77-4943-8659-aa14b69f6908
# ╠═0143579d-3dad-43ff-b504-9af0a50fa660
# ╟─a83cd7a2-7045-4ba2-b8f2-4a001abf7789
# ╠═3e96d66a-f0ac-4c27-8247-962957ed9d23
# ╟─13874a32-7acd-4b70-86cb-97106b0f8ba5
# ╟─8275656a-4d27-4f17-8abf-df006d45e8f9
# ╠═55255948-5e85-441e-adc4-f4f46f343215
# ╟─d6fa4369-deb8-44fa-8dcc-03711a1c3118
# ╠═02cdaaf1-966f-4d63-bdbb-75a437b46e30
# ╠═3635389e-1ee1-4e39-9836-66cc098ecc44
# ╠═708cf089-9051-45de-84de-92b0cb2556c8
# ╠═7a53ee87-d302-47ef-a5b6-f6650fefeb10
# ╠═7567da79-9657-42c3-860a-7b8026e70ab7
# ╠═496dd7f5-2669-4d5e-8f75-cefb33931ba6
# ╠═435ad5f2-5b50-4bf4-adb1-d3253889291c
# ╠═debf5715-18ee-4919-8585-4216924716c5
# ╠═6d9bf8e4-0aea-4f1b-ac53-0bd2354aa3af
# ╠═3a7eacb2-9b3e-4805-ad13-4e53a061ca0a
# ╠═8ed7b364-8525-42a9-941d-c6b28f113be9
# ╠═39a7f57c-bd7a-4fbd-9486-01098f198ab1
# ╠═3ccb5421-53ac-4deb-acc8-42670c740ec8
# ╠═4798788e-fd6b-4a5b-9115-dc249f81c881
# ╠═7d2622eb-5ee8-4763-9e87-a284f30f0c17
# ╠═9d32ba80-b542-451d-8a96-4b288f6ec80d
# ╠═f3df4abd-7b31-491c-9833-ff4744bc0766
# ╟─00000000-0000-0000-0000-000000000001
# ╟─00000000-0000-0000-0000-000000000002
