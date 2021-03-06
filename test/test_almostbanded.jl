using SemiseparableMatrices, BandedMatrices, Test, LinearAlgebra, MatrixFactorizations, LazyArrays, ArrayLayouts, Random
import BandedMatrices: _BandedMatrix, _banded_qr!
import SemiseparableMatrices: bandpart, fillpart, AlmostBandedLayout
import MatrixFactorizations: QRPackedQ

Random.seed!(0)

@testset "AlmostBandedMatrix" begin
    @testset "Slices" begin
        n = 80
        A = AlmostBandedMatrix(BandedMatrix(fill(2.0,n,n),(1,1)), LowRankMatrix(fill(3.0,n), ones(1,n)))
        V = view(A,1:3,1:3)
        @test MemoryLayout(typeof(A)) == MemoryLayout(typeof(V)) == AlmostBandedLayout()
        @test AlmostBandedMatrix(V) == A[1:3,1:3] == V
        @test A[1:3,1:3] isa AlmostBandedMatrix 
    end

    @testset "Triangular" begin
        n = 80
        A = AlmostBandedMatrix(BandedMatrix(fill(2.0,n,n),(1,1)), LowRankMatrix(fill(3.0,n), ones(1,n))) 
        b = randn(n)
        @test MemoryLayout(typeof(UpperTriangular(A))) == TriangularLayout{'U','N',AlmostBandedLayout}()
        @test UpperTriangular(Matrix(A)) \ b ≈ UpperTriangular(A) \ b
        @test UnitUpperTriangular(Matrix(A)) \ b ≈ UnitUpperTriangular(A) \ b
        @test LowerTriangular(Matrix(A)) \ b ≈ LowerTriangular(A) \ b
        @test UnitLowerTriangular(Matrix(A)) \ b ≈ UnitLowerTriangular(A) \ b
    end

    @testset "QR" begin
        n = 80
        A = AlmostBandedMatrix(BandedMatrix(fill(2.0,n,n),(1,1)), LowRankMatrix(fill(3.0,n), ones(1,n)))
        A[band(0)] .+= 1:n
        Ã = deepcopy(A)
        B,L = bandpart(A),fillpart(A)
        Ā = AlmostBandedMatrix(A,(1,2))
        @test A == Ā == B + triu(Matrix(L),2)
        F = qr(A)
        @test F.Q isa LinearAlgebra.QRPackedQ{Float64,<:BandedMatrix}
        @test F.R isa UpperTriangular{Float64,<:AlmostBandedMatrix}
        @test F.Q' * A ≈ F.R
        @test A == Ã

        Ā = AlmostBandedMatrix(A,(1,2))
        τ = Vector{Float64}(undef,n)
        @inferred(SemiseparableMatrices._almostbanded_qr!(Ā,τ))

        
        b = randn(n)
        @test A \ b ≈ Matrix(A) \ b 
        @test all(A \ b .=== F \ b .=== F.R \ (F.Q'*b)) 
    end
end

