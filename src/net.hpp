// Local-network multiplayer: every headset broadcasts its head and hands over
// UDP on the LAN and listens for everyone else's. No server, one room.
// Remote poses are rendered kInterpDelay seconds in the past, interpolated
// between the packets either side, so they move smoothly despite jitter.

#pragma once

#include <cstdint>
#include <map>
#include <vector>

// Head, left hand, right hand: position xyz + quaternion xyzw each.
struct NetPose
{
    float v[21] = {};
};

struct RemotePlayer
{
    uint32_t id = 0;
    NetPose pose;
};

class LanSession
{
public:
    static constexpr uint16_t kPort = 47777;
    static constexpr double kInterpDelay = 0.1;
    static constexpr double kTimeout = 2.0;

    // Opens the broadcast socket. Returns false if networking is unavailable.
    bool start();
    void stop();

    uint32_t id() const { return m_id; }
    void send(const NetPose& pose);
    // Drains incoming packets; now is a monotonic time in seconds.
    void poll(double now);
    // Everyone heard from recently, interpolated, ordered by id.
    std::vector<RemotePlayer> sample(double now);

private:
    struct Snapshot
    {
        double time;
        NetPose pose;
    };
    struct Peer
    {
        std::vector<Snapshot> snapshots; // oldest first
        double lastHeard = 0;
        uint32_t lastSeq = 0;
    };

    int m_socket = -1;
    uint32_t m_id = 0;
    uint32_t m_seq = 0;
    uint32_t m_broadcastAddr = 0; // network byte order
    std::map<uint32_t, Peer> m_peers;
};
