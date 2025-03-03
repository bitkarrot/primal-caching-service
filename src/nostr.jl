module Nostr

import StaticArrays
import JSON
import SHA

struct EventId; hash::StaticArrays.SVector{32, UInt8}; end
struct PubKeyId; pk::StaticArrays.SVector{32, UInt8}; end
URL = String
struct Sig; sig::StaticArrays.SVector{64, UInt8}; end

Base.convert(::Type{EventId}, arr::Vector{UInt8}) = EventId(arr)
Base.convert(::Type{PubKeyId}, arr::Vector{UInt8}) = PubKeyId(arr)
Base.convert(::Type{Sig}, arr::Vector{UInt8}) = Sig(arr)

abstract type Tag end
# struct TagE <: Tag
#     event_id::EventId
#     relay_url::Union{URL,Nothing}
#     extra::Vector{Any}
# end
# struct TagP <: Tag
#     pubkey_id::PubKeyId
#     relay_url::Union{URL,Nothing}
#     extra::Vector{Any}
# end
struct TagAny <: Tag
    fields::Vector{Any}
end

@enum Kind::Int begin
    SET_METADATA=0
    TEXT_NOTE=1
    RECOMMEND_SERVER=2
    CONTACT_LIST=3
    DIRECT_MESSAGE=4
    REPOST=6
    REACTION=7
    ZAP_NOTE=9735
end

struct Event
    id::EventId # <32-bytes lowercase hex-encoded sha256 of the the serialized event data>
    pubkey::PubKeyId # <32-bytes lowercase hex-encoded public key of the event creator>,
    created_at::Int # <unix timestamp in seconds>,
    kind::Int # <integer>,
    tags::Vector{Tag}
    content::String # <arbitrary string>,
    sig::Sig # <64-bytes signature of the sha256 hash of the serialized event data, which is the same as the id field>
end


function parse_pubkey_id(s::String)
    if startswith(s, "npub")
        PubKeyId(zeros(UInt8, 32)) # TODO fix this
    else
        PubKeyId(hex2bytes(s))
    end
end

function vec2tags(tags::Vector)
    map(tags) do elem
        # if     elem[1] == "e"; return TagE(EventId(hex2bytes(elem[2])), (length(elem) >= 3 ? elem[3] : nothing), [])
        # elseif elem[1] == "p"; return TagP(parse_pubkey_id(elem[2]), (length(elem) >= 3 ? elem[3] : nothing), [])
        # else                   return TagAny(elem)
        # end
        TagAny(elem)
    end
end

function dict2event(d::Dict)
    Event(EventId(hex2bytes(d["id"])),
          PubKeyId(hex2bytes(d["pubkey"])),
          d["created_at"],
          d["kind"],
          vec2tags(d["tags"]),
          d["content"],
          Sig(hex2bytes(d["sig"])))
end
Event(d::Dict) = dict2event(d)

function event2dict(e::Event) # TODO compare with Utils.obj2dict
    Dict(:id=>JSON.lower(e.id),
         :pubkey=>JSON.lower(e.pubkey),
         :created_at=>e.created_at,
         :kind=>e.kind,
         :tags=>map(JSON.lower, e.tags),
         :content=>e.content,
         :sig=>JSON.lower(e.sig))
end

for ty in [EventId, PubKeyId, Sig]
    eval(:($(ty.name.name)(hex::String) = $(ty.name.name)(hex2bytes(hex))))
    eval(:(hex(v::$(ty.name.name)) = bytes2hex(v.$(fieldnames(ty)[1]))))
    eval(:(Base.show(io::IO, v::$(ty.name.name)) = print(io, string($(ty.name.name))*"("*repr(hex(v))*")")))
end

JSON.lower(eid::EventId) = hex(eid)
JSON.lower(pubkey::PubKeyId) = hex(pubkey)
JSON.lower(sig::Sig) = hex(sig)
# json_lower_relay_url(relay_url) = isnothing(relay_url) ? [] : [relay_url]
# JSON.lower(tag::TagE) = ["e", tag.event_id, json_lower_relay_url(tag.relay_url)..., tag.extra...]
# JSON.lower(tag::TagP) = ["p", tag.pubkey_id, json_lower_relay_url(tag.relay_url)..., tag.extra...]
JSON.lower(tag::TagAny) = tag.fields

include("schnorr.jl")

#TODO: check that event id is equal to sha256 of whole contents
Schnorr.verify(ctx::Schnorr.Secp256k1Ctx, e::Event) = Schnorr.verify(ctx, collect(e.id.hash), collect(e.pubkey.pk), collect(e.sig.sig))
Schnorr.verify(e::Event) = Schnorr.verify(collect(e.id.hash), collect(e.pubkey.pk), collect(e.sig.sig))

function verify(e::Event)
    e.id == ([0,
              e.pubkey,
              e.created_at,
              e.kind,
              e.tags,
              e.content,
             ] |> JSON.json |> SHA.sha256 |> EventId) || return false
    Schnorr.verify(e) || return false
    true
end

re_hrp = r"^(note|npub|naddr|nevent|nprofile)\w+$"
function bech32_decode(s::AbstractString)
    m = match(re_hrp, s)
    isnothing(m) && error("invalid hrp")
    hrp = m.captures[1]
    bech32_decode(s, hrp)
end
function bech32_decode(s::AbstractString, hrp::AbstractString)
    outdata = zeros(UInt8, 100)
    outdata_len = [Csize_t(0)]
    input = string(s)*"\x00"
    hrp = string(hrp)*"\x00"
    GC.@preserve input hrp if (@ccall :libbech32.nostr_bech32_decode(pointer(outdata)::Ptr{Cchar}, 
                                                                     pointer(outdata_len)::Ptr{Csize_t}, 
                                                                     pointer(hrp)::Ptr{Cchar}, 
                                                                     pointer(input)::Ptr{Cchar})::Clong) == 1
        return outdata[1:outdata_len[1]]
    end
    nothing
end

bech32_encode(input::EventId) = bech32_encode(collect(input.hash), "note")
bech32_encode(input::PubKeyId) = bech32_encode(collect(input.pk), "npub")
function bech32_encode(input::Vector{UInt8}, hrp::AbstractString)
    outdata = zeros(UInt8, 100)
    hrp = string(hrp)*"\x00"
    GC.@preserve input hrp if (@ccall :libbech32.nostr_bech32_encode(pointer(outdata)::Ptr{Cchar}, 
                                                                     pointer(hrp)::Ptr{Cchar}, 
                                                                     0::Clong, # witver
                                                                     pointer(input)::Ptr{Cchar},
                                                                     length(input)::Csize_t)::Clong) == 1
        return String(outdata[1:findfirst([0x00], outdata).start-1])
    end
    nothing
end

# import JSON
# begin
#     e = Main.evts[1] |> Dict{String,Any}
#     e["tags"] isa String && (e["tags"] = JSON.parse(e["tags"]))
#     e["created_at"] = parse(Int, e["created_at"])
#     e["kind"] = parse(Int, e["kind"])
#     ee = dict2event(e)
#     ee |> display
#     Main.eval(:(ee=$ee))
#     @show Schnorr.verify(ee)
# end

end
