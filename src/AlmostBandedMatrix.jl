## AlmostBandedMatrix



struct AlmostBandedMatrix{T,D,A,B,R} <: AbstractMatrix{T}
    bands::BandedMatrix{T,D,R}
    fill::LowRankMatrix{T,A,B}
    AlmostBandedMatrix{T,D,A,B,R}(bands, fill) where {T,D,A,B,R} = new{T,D,A,B,R}(bands,fill)
end

function AlmostBandedMatrix{T}(bands::BandedMatrix{T,D,R}, fill::LowRankMatrix{T,A,B}) where {T,D,A,B,R}
    if size(bands) ≠ size(fill)
        error("Data and fill must be compatible size")
    end
    AlmostBandedMatrix{T,D,A,B,R}(bands,fill)
end

AlmostBandedMatrix(bands::BandedMatrix, fill::LowRankMatrix) =
    AlmostBandedMatrix{promote_type(eltype(bands),eltype(fill))}(bands,fill)

AlmostBandedMatrix(bands::AbstractMatrix, fill::AbstractMatrix) = 
    AlmostBandedMatrix(BandedMatrix(bands), LowRankMatrix(fill))

AlmostBandedMatrix{T}(::UndefInitializer, nm::NTuple{2,Integer}, lu::NTuple{2,Integer}, r::Integer) where {T} =
    AlmostBandedMatrix(BandedMatrix{T}(undef,nm,lu), LowRankMatrix{T}(undef,nm,r))

function AlmostBandedMatrix{T}(A::AlmostBandedMatrix, (l,u)::NTuple{2,Integer}) where T
    B_in,L = bandpart(A),fillpart(A)
    l_in,u_in = bandwidths(B_in)
    B = BandedMatrix(B_in, (l,u))
    for b = u_in+1:u
        B[band(b)] .= L[band(b)]
    end
    AlmostBandedMatrix{T}(B, copy(L))
end

AlmostBandedMatrix(A::AlmostBandedMatrix{T}, (l,u)::NTuple{2,Integer}) where T = AlmostBandedMatrix{T}(A, (l,u))



AlmostBandedMatrix{T}(Z::Zeros, lu::NTuple{2,Integer}, r::Integer) where {T} =
    AlmostBandedMatrix(BandedMatrix{T}(Z, lu), LowRankMatrix{T}(Z, r))

AlmostBandedMatrix(Z::AbstractMatrix, lu::NTuple{2,Integer}, r::Integer) =
    AlmostBandedMatrix{eltype(Z)}(Z, lu, r)

AlmostBandedMatrix(A::AbstractMatrix) = AlmostBandedMatrix(bandpart(A), fillpart(A))    

for MAT in (:AlmostBandedMatrix, :AbstractMatrix, :AbstractArray)
    @eval convert(::Type{$MAT{T}}, A::AlmostBandedMatrix) where {T} =
        AlmostBandedMatrix(AbstractMatrix{T}(A.bands),AbstractMatrix{T}(A.fill))
end


bandpart(A::AlmostBandedMatrix) = A.bands
fillpart(A::AlmostBandedMatrix) = A.fill

size(A::AlmostBandedMatrix) = size(A.bands)
Base.IndexStyle(::Type{ABM}) where {ABM<:AlmostBandedMatrix} =
    IndexCartesian()


function getindex(B::AlmostBandedMatrix, k::Integer, j::Integer)
    if j > k + bandwidth(B.bands,2)
        B.fill[k,j]
    else
        B.bands[k,j]
    end
end

@inline getindex(A::AlmostBandedMatrix, kr::Colon, jr::Colon) = lazy_getindex(A, kr, jr)
@inline getindex(A::AlmostBandedMatrix, kr::Colon, jr::AbstractUnitRange) = lazy_getindex(A, kr, jr)
@inline getindex(A::AlmostBandedMatrix, kr::AbstractUnitRange, jr::Colon) = lazy_getindex(A, kr, jr)
@inline getindex(A::AlmostBandedMatrix, kr::AbstractUnitRange, jr::AbstractUnitRange) = lazy_getindex(A, kr, jr)
@inline getindex(A::AlmostBandedMatrix, kr::AbstractVector, jr::AbstractVector) = lazy_getindex(A, kr, jr)
@inline getindex(A::AlmostBandedMatrix, kr::Colon, jr::AbstractVector) = lazy_getindex(A, kr, jr)
@inline getindex(A::AlmostBandedMatrix, kr::AbstractVector, jr::Colon) = lazy_getindex(A, kr, jr)

# can only change the bands, not the fill
function setindex!(B::AlmostBandedMatrix, v, k::Integer, j::Integer)
    l,u = bandwidths(bandpart(B))
    if j-k ≤ u
        B.bands[k,j] = v
    else
        B.fill[k,j] = v
    end
    B
end

function triu!(A::AlmostBandedMatrix) 
    triu!(bandpart(A))
    A
end


struct AlmostBandedLayout <: MemoryLayout end
MemoryLayout(::Type{<:AlmostBandedMatrix}) = AlmostBandedLayout()
sublayout(::AlmostBandedLayout, ::Type{<:Tuple{AbstractUnitRange{Int},AbstractUnitRange{Int}}}) = 
    AlmostBandedLayout()

sub_materialize(::AlmostBandedLayout, V) = AlmostBandedMatrix(V)

bandpart(V::SubArray) = view(bandpart(parent(V)), parentindices(V)...)
fillpart(V::SubArray) = view(fillpart(parent(V)), parentindices(V)...)

###
# QR
##

@lazyldiv AlmostBandedMatrix

factorize(A::AlmostBandedMatrix) = qr(A)
qr(A::AlmostBandedMatrix) = almostbanded_qr(A)
qr!(A::AlmostBandedMatrix) = almostbanded_qr!(A)

almostbanded_qr(A) = _almostbanded_qr(axes(A), A)
function _almostbanded_qr(_, A) 
    l,u = bandwidths(bandpart(A))
    qr!(AlmostBandedMatrix{float(eltype(A))}(A, (l,l+u)))
end


function _almostbanded_qr!(A::AlmostBandedMatrix{T} , τ::AbstractVector{T}) where T
    B,L = bandpart(A),fillpart(A)
    l,u = bandwidths(B)

    m,n = size(A)
    k = 1
    while k ≤ min(m - 1 + !(T<:Real), n)
        kr = k:min(k+l+u,m)
        jr1 = k:min(k+u,n)
        jr2 = k+u+1:min(kr[end]+u,n)
        S = @view B[kr,jr1]
        τv = view(τ,jr1)

        R,_ = _banded_qr!(S, τv)
        Q = QRPackedQ(R,τv)

        B_right = @view B[kr,jr2] 
        L_right = @view L[kr,jr2]
        # The following writes it as Q' * (B -L) + Q'*L 
        # that is,  subtract out L from B, apply Q' to both
        # and add it back in again
        for j=1:size(B_right,2)
            B_right[j+1:end,j] -= L_right[j+1:end,j]
        end
        lmul!(Q', B_right)
        U,V = arguments(L_right)
        lmul!(Q', U)
        for j=1:size(B_right,2)
            B_right[j+1:end,j] += L_right[j+1:end,j]
        end
        k = jr1[end]+1
    end
    A, τ
end

function almostbanded_qr!(R::AbstractMatrix{T}, τ) where T 
    _almostbanded_qr!(R, τ)
    QR(R, τ)
 end
 
almostbanded_qr!(R::AbstractMatrix{T}) where T = almostbanded_qr!(R, zeros(T, min(size(R)...)))

getQ(F::QR{<:Any,<:AlmostBandedMatrix}) = LinearAlgebra.QRPackedQ(bandpart(F.factors), F.τ)
getR(F::QR{<:Any,<:AlmostBandedMatrix}) = UpperTriangular(F.factors)

function ldiv!(A::QR{<:Any,<:AlmostBandedMatrix}, B::AbstractVector)
    R = A.factors
    lmul!(adjoint(A.Q), B)
    B .= Ldiv(UpperTriangular(R), B)
    B
end

function ldiv!(A::QR{<:Any,<:AlmostBandedMatrix}, B::AbstractMatrix)
    R = A.factors
    lmul!(adjoint(A.Q), B)
    B .= Ldiv(UpperTriangular(R), B)
    B
end


###
# UpperTriangular ldiv!
##

triangularlayout(::Type{Tri}, ::ML) where {Tri,ML<:AlmostBandedLayout} = Tri{ML}()

@lazyldiv UpperTriangular{T, <:AlmostBandedMatrix{T}} where T
@lazyldiv UnitUpperTriangular{T, <:AlmostBandedMatrix{T}} where T
@lazyldiv LowerTriangular{T, <:AlmostBandedMatrix{T}} where T
@lazyldiv UnitLowerTriangular{T, <:AlmostBandedMatrix{T}} where T


function _almostbanded_upper_ldiv!(Tri, R::AbstractMatrix, b::AbstractVector{T}, buffer) where T
    B = R.bands
    L = R.fill
    U,V = arguments(L)
    fill!(buffer, zero(T))

    l,u = bandwidths(B)
    k = n = size(R,2)

    while k > 0
        kr = max(1,k-u):k
        jr1 = k+1:k+u+1
        jr2 = k+u+2:k+2u+2
        bv = view(b,kr)
        if jr2[1] < n
            muladd!(one(T),view(V,:,jr2),view(b,jr2),one(T),buffer)
            muladd!(-one(T),view(U,kr,:),buffer,one(T),bv)
        end
        if jr1[1] < n
            muladd!(-one(T),view(R,kr,jr1),view(b,jr1),one(T),bv)
        end
        materialize!(Ldiv(Tri(view(R.bands,kr,kr)), bv))
        k = kr[1]-1
    end
    b
end

@inline function materialize!(M::MatLdivVec{TriangularLayout{'U','N',AlmostBandedLayout}})
    R,x = M.A,M.B
    A = triangulardata(R)
    r = size(arguments(fillpart(A))[1],2)
    _almostbanded_upper_ldiv!(UpperTriangular, A, x, Vector{eltype(M)}(undef, r))
    x
end

@inline function materialize!(M::MatLdivVec{TriangularLayout{'U','U',AlmostBandedLayout}})
    R,x = M.A,M.B
    A = triangulardata(R)
    r = size(arguments(fillpart(A))[1],2)
    _almostbanded_upper_ldiv!(UnitUpperTriangular, A, x, Vector{eltype(M)}(undef, r))
    x
end

@inline function materialize!(M::MatLdivVec{TriangularLayout{'L','N',AlmostBandedLayout}})
    R,x = M.A,M.B
    A = triangulardata(R)
    materialize!(Ldiv(LowerTriangular(bandpart(A)),x))
    x
end

@inline function materialize!(M::MatLdivVec{TriangularLayout{'L','U',AlmostBandedLayout}})
    R,x = M.A,M.B
    A = triangulardata(R)
    materialize!(Ldiv(UnitLowerTriangular(bandpart(A)),x))
    x
end
