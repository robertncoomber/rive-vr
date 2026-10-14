#include "net.hpp"

#include <android/log.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <random>

#define TAG "RiveNet"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace
{
constexpr uint32_t kMagic = 0x32525652; // "RVR2"
constexpr size_t kMaxSnapshots = 32;
constexpr size_t kOffsetWindow = 64;
constexpr double kStatsInterval = 3.0;

#pragma pack(push, 1)
struct Packet
{
    uint32_t magic;
    uint32_t id;
    uint32_t seq;
    double sendTime; // sender's monotonic clock, seconds
    float pose[21];
};
#pragma pack(pop)

// The Wi-Fi interface's subnet broadcast address (more reliably delivered
// than 255.255.255.255), falling back to the limited broadcast address.
uint32_t findBroadcastAddress()
{
    uint32_t result = htonl(INADDR_BROADCAST);
    ifaddrs* list = nullptr;
    if (getifaddrs(&list) != 0)
    {
        return result;
    }
    for (ifaddrs* ifa = list; ifa != nullptr; ifa = ifa->ifa_next)
    {
        if (ifa->ifa_addr == nullptr || ifa->ifa_addr->sa_family != AF_INET ||
            (ifa->ifa_flags & IFF_LOOPBACK) || !(ifa->ifa_flags & IFF_BROADCAST) ||
            ifa->ifa_broadaddr == nullptr)
        {
            continue;
        }
        result = reinterpret_cast<sockaddr_in*>(ifa->ifa_broadaddr)->sin_addr.s_addr;
        char text[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &result, text, sizeof(text));
        LOGI("Broadcasting on %s (%s)", ifa->ifa_name, text);
        if (strncmp(ifa->ifa_name, "wlan", 4) == 0)
        {
            break;
        }
    }
    freeifaddrs(list);
    return result;
}

void lerpPose(const NetPose& a, const NetPose& b, float t, NetPose& out)
{
    for (int part = 0; part < 3; ++part)
    {
        const int o = part * 7;
        for (int i = 0; i < 3; ++i)
        {
            out.v[o + i] = a.v[o + i] + (b.v[o + i] - a.v[o + i]) * t;
        }
        // Normalised lerp along the shorter arc.
        float dot = 0;
        for (int i = 3; i < 7; ++i)
        {
            dot += a.v[o + i] * b.v[o + i];
        }
        const float sign = dot < 0 ? -1.0f : 1.0f;
        float len = 0;
        for (int i = 3; i < 7; ++i)
        {
            out.v[o + i] = a.v[o + i] + (sign * b.v[o + i] - a.v[o + i]) * t;
            len += out.v[o + i] * out.v[o + i];
        }
        len = len > 0 ? 1.0f / std::sqrt(len) : 1.0f;
        for (int i = 3; i < 7; ++i)
        {
            out.v[o + i] *= len;
        }
    }
}
} // namespace

bool LanSession::start()
{
    m_id = std::random_device{}() | 1u; // never 0
    m_socket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (m_socket < 0)
    {
        LOGE("socket() failed: %s", strerror(errno));
        return false;
    }
    int on = 1;
    setsockopt(m_socket, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));
    setsockopt(m_socket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    fcntl(m_socket, F_SETFL, fcntl(m_socket, F_GETFL, 0) | O_NONBLOCK);

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(m_socket, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
    {
        LOGE("bind() failed: %s", strerror(errno));
        stop();
        return false;
    }
    m_broadcastAddr = findBroadcastAddress();
    LOGI("LAN session up: player %08x, port %u", m_id, kPort);
    return true;
}

void LanSession::stop()
{
    if (m_socket >= 0)
    {
        close(m_socket);
        m_socket = -1;
    }
}

void LanSession::send(const NetPose& pose, double now)
{
    if (m_socket < 0)
    {
        return;
    }
    Packet packet;
    packet.magic = kMagic;
    packet.id = m_id;
    packet.seq = ++m_seq;
    packet.sendTime = now;
    memcpy(packet.pose, pose.v, sizeof(packet.pose));

    // Every frame, direct to each known peer.
    for (auto& [id, peer] : m_peers)
    {
        sendto(m_socket,
               &packet,
               sizeof(packet),
               0,
               reinterpret_cast<const sockaddr*>(&peer.addr),
               sizeof(peer.addr));
    }
    // A few times a second, broadcast so new peers can find us.
    if (now - m_lastHello >= kHelloInterval)
    {
        m_lastHello = now;
        sockaddr_in to{};
        to.sin_family = AF_INET;
        to.sin_port = htons(kPort);
        to.sin_addr.s_addr = m_broadcastAddr;
        sendto(m_socket, &packet, sizeof(packet), 0, reinterpret_cast<sockaddr*>(&to), sizeof(to));
    }
}

void LanSession::poll(double now)
{
    if (m_socket < 0)
    {
        return;
    }
    Packet packet;
    sockaddr_in from{};
    for (;;)
    {
        socklen_t fromLen = sizeof(from);
        ssize_t n = recvfrom(m_socket,
                             &packet,
                             sizeof(packet),
                             0,
                             reinterpret_cast<sockaddr*>(&from),
                             &fromLen);
        if (n < 0)
        {
            break; // EAGAIN: drained
        }
        if (n != sizeof(packet) || packet.magic != kMagic || packet.id == m_id)
        {
            continue; // not ours, or our own broadcast looping back
        }
        auto [it, isNew] = m_peers.try_emplace(packet.id);
        Peer& peer = it->second;
        if (isNew)
        {
            char text[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &from.sin_addr, text, sizeof(text));
            LOGI("Player %08x joined from %s", packet.id, text);
            peer.statsStart = now;
        }
        peer.addr = from;
        peer.addr.sin_port = htons(kPort);
        if (!isNew && packet.seq <= peer.lastSeq && peer.lastSeq - packet.seq < 1000)
        {
            continue; // duplicate (broadcast + unicast) or late
        }
        peer.lastSeq = packet.seq;
        peer.lastHeard = now;

        // Clock offset: the smallest recent arrival - send gap.
        peer.offsets.push_back(now - packet.sendTime);
        if (peer.offsets.size() > kOffsetWindow)
        {
            peer.offsets.erase(peer.offsets.begin());
        }

        Snapshot snap{packet.sendTime, {}};
        memcpy(snap.pose.v, packet.pose, sizeof(packet.pose));
        peer.snapshots.push_back(snap);
        if (peer.snapshots.size() > kMaxSnapshots)
        {
            peer.snapshots.erase(peer.snapshots.begin());
        }

        if (peer.lastArrival > 0)
        {
            peer.maxGap = std::max(peer.maxGap, now - peer.lastArrival);
        }
        peer.lastArrival = now;
        peer.received++;
        if (now - peer.statsStart >= kStatsInterval)
        {
            LOGI("Player %08x: %.0f packets/s, longest gap %.0f ms",
                 it->first,
                 peer.received / (now - peer.statsStart),
                 peer.maxGap * 1000);
            peer.received = 0;
            peer.maxGap = 0;
            peer.statsStart = now;
        }
    }
}

std::vector<RemotePlayer> LanSession::sample(double now)
{
    std::vector<RemotePlayer> result;
    for (auto it = m_peers.begin(); it != m_peers.end();)
    {
        Peer& peer = it->second;
        if (now - peer.lastHeard > kTimeout || peer.snapshots.empty())
        {
            LOGI("Player %08x left", it->first);
            it = m_peers.erase(it);
            continue;
        }
        // Render time on the sender's clock.
        const double offset = *std::min_element(peer.offsets.begin(), peer.offsets.end());
        const double renderTime = now - offset - kInterpDelay;
        RemotePlayer player;
        player.id = it->first;
        const auto& snaps = peer.snapshots;
        if (renderTime <= snaps.front().sendTime)
        {
            player.pose = snaps.front().pose;
        }
        else if (renderTime >= snaps.back().sendTime)
        {
            player.pose = snaps.back().pose; // starved: hold the newest
        }
        else
        {
            size_t i = 1;
            while (snaps[i].sendTime < renderTime)
            {
                ++i;
            }
            const Snapshot& a = snaps[i - 1];
            const Snapshot& b = snaps[i];
            const double span = b.sendTime - a.sendTime;
            const float t = span > 0 ? (float)((renderTime - a.sendTime) / span) : 1.0f;
            lerpPose(a.pose, b.pose, t, player.pose);
        }
        result.push_back(player);
        ++it;
    }
    return result;
}
