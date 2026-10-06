#include "include/MuseNoiseNative.h"
#include <xplat/noise/core/ClientSession.h>
#include <xplat/noise/core/Secret.h>
#include <cstring>
#include <new>
#include <vector>
using namespace musegadgets::noise::core;
namespace {
class AppleCrypto final : public CryptoBackend {
  MuseCrypto f;
  Status call(int op, ConstByteSpan a, ConstByteSpan b, ConstByteSpan c,
              ConstByteSpan d, ByteSpan out) noexcept {
    return f(op,a.data(),a.size(),b.data(),b.size(),c.data(),c.size(),
             d.data(),d.size(),out.data(),out.size()) ? OkStatus() : Status::Unauthenticated();
  }
public:
  explicit AppleCrypto(MuseCrypto callback) : f(callback) {}
  Status Random(ByteSpan out) noexcept override { return call(0,{},{},{},{},out); }
  Status X25519GenerateKeypair(ByteSpan priv, ByteSpan pub) noexcept override {
    uint8_t both[64]; auto s=call(1,{},{},{},{},ByteSpan(both,64));
    if(s.ok()) { std::memcpy(priv.data(),both,32); std::memcpy(pub.data(),both+32,32); }
    Zeroize(both,64); return s;
  }
  Status X25519PublicFromPrivate(ConstByteSpan priv, ByteSpan pub) noexcept override { return call(2,priv,{},{},{},pub); }
  Status X25519Dh(ConstByteSpan priv, ConstByteSpan pub, ByteSpan out) noexcept override { return call(3,priv,pub,{},{},out); }
  Status Sha256(ConstByteSpan a, ByteSpan out) noexcept override { return call(4,a,{},{},{},out); }
  Status Sha256Concat(ConstByteSpan a, ConstByteSpan b, ByteSpan out) noexcept override { return call(5,a,b,{},{},out); }
  Status HkdfSha256(ConstByteSpan salt, ConstByteSpan ikm, ConstByteSpan info, Span<ByteSpan> outputs) noexcept override {
    uint8_t bytes[96]; if(outputs.size()>3) return Status::InvalidArgument();
    auto s=call(6,salt,ikm,info,{},ByteSpan(bytes,outputs.size()*32));
    if(s.ok()) for(size_t i=0;i<outputs.size();i++) std::memcpy(outputs[i].data(),bytes+i*32,32);
    Zeroize(bytes,sizeof(bytes)); return s;
  }
  Status Aes256GcmSeal(ConstByteSpan k, ConstByteSpan n, ConstByteSpan ad, ConstByteSpan plain, ByteSpan out) noexcept override { return call(7,k,n,ad,plain,out); }
  Status Aes256GcmOpen(ConstByteSpan k, ConstByteSpan n, ConstByteSpan ad, ConstByteSpan cipher, ByteSpan out) noexcept override { return call(8,k,n,ad,cipher,out); }
};
struct Session {
  AppleCrypto crypto;
  ClientSession client;
  std::vector<uint8_t> frame, envelope, transport, response;
  HeaderView headers[64];
  explicit Session(MuseCrypto f) : crypto(f), client(crypto), frame(1024*1024),
    envelope(1024*1024), transport(65536), response(1024*1024) {}
};
ByteSpan span(std::vector<uint8_t>& v) { return {v.data(),v.size()}; }
int code(Status s) { return static_cast<int>(s.code()); }
}
extern "C" {
void *muse_noise_create(MuseCrypto f) {
  if(!f) return nullptr;
  try { return new Session(f); } catch(...) { return nullptr; }
}
void muse_noise_destroy(void *s) { delete static_cast<Session*>(s); }
int muse_noise_handshake(void *p,int step,const uint8_t *in,size_t n,uint8_t *out,size_t cap,size_t *written) {
  auto& s=*static_cast<Session*>(p); *written=0;
  if(step==1) { auto r=s.client.WriteHandshakeMessage1({out,cap}); *written=r.size(); return code(r.status()); }
  if(step==2) return code(s.client.ReadHandshakeMessage2({in,n},{out,cap},*written));
  if(step==3) { auto r=s.client.WriteHandshakeMessage3({},{out,cap}); *written=r.size(); return code(r.status()); }
  return 3;
}
int muse_noise_request(void *p,int64_t id,const char *path,const uint8_t *body,size_t n,int end) {
  auto& s=*static_cast<Session*>(p);
  HeaderView h[]={{{"content-type",12},{"application/json",16}},{{"accept",6},{"application/x-ndjson",20}}};
  ApplicationRequestView request{{"POST",4},{path,std::strlen(path)},{h,2},{body,n},end!=0};
  return code(s.client.StartOutboundApplicationRequest(ServiceType::Daemon,id,request,span(s.frame),span(s.envelope)).status());
}
int muse_noise_body(void *p,int64_t id,const uint8_t *body,size_t n,int end) {
  auto& s=*static_cast<Session*>(p);
  return code(s.client.StartOutboundBodyChunk(ServiceType::Daemon,id,{{body,n},end!=0},span(s.frame),span(s.envelope)).status());
}
int muse_noise_next(void *p,uint8_t *out,size_t cap,size_t *written) {
  auto& s=*static_cast<Session*>(p); *written=0;
  if(!s.client.HasOutboundWebSocketPayload()) return 0;
  auto r=s.client.WriteNextOutboundWebSocketPayload({out,cap}); *written=r.size(); return code(r.status());
}
int muse_noise_receive(void *p,const uint8_t *in,size_t n,int *kind,int64_t *id,int *status,int *end,uint8_t *body,size_t cap,size_t *written) {
  auto& s=*static_cast<Session*>(p); *kind=0; *written=0; *status=0; *end=0;
  if(n>65535) return 8;
  auto r=s.client.ProcessInboundWebSocketPayload({in,n},span(s.transport),span(s.response),{s.headers,64});
  if(!r.ok()) return code(r.status);
  if(r.frame_status!=InboundFrameStatus::Complete) return 0;
  *id=r.frame.stream_id; ConstByteSpan data;
  switch(r.frame.kind) {
    case ServiceFrameKind::Response: *kind=1; *status=r.frame.response.status;
      *end=r.frame.response.end_body; data=r.frame.response.body; break;
    case ServiceFrameKind::BodyChunk: *kind=2; *end=r.frame.body_chunk.end_body;
      data=r.frame.body_chunk.data; break;
    case ServiceFrameKind::Reset: *kind=3; *status=static_cast<int>(r.frame.reset.code); break;
    default: return 15;
  }
  if(data.size()>cap) return 8;
  if(data.size()) std::memcpy(body,data.data(),data.size());
  *written=data.size(); return 0;
}
}
