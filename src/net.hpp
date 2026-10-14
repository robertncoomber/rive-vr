// Local-network multiplayer, no server, one room.
//
// Discovery is by broadcast: a few times a second each headset broadcasts
// its pose so others learn its address. Every frame's pose then goes direct
// (unicast) to each known peer. Wi-Fi access points hold broadcast traffic
// for power-saving clients and release it only every DTIM beacon (a few
// times a second), which made remote players move at ~5 fps; unicast is
// delivered as it comes.
//
// Packets carry the sender's clock. Remote poses are rendered kInterpDelay (130 ms;
// Quest Wi-Fi shows occasional 125 ms gaps)
// behind the newest packet on that clock (the clock offset is the smallest
// recent arrival-minus-send gap, which filters out Wi-Fi queueing) and are
// interpolated between the packets either side, so leftover jitter is hidden.

#pragma once

#include <netinet/in.h>

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
    static constexpr double kInterpDelay = 0.13;
    static constexpr double kTimeout = 2.0;
    static constexpr double kHelloInterval = 0.5;

    // Opens the socket. Returns false if networking is unavailable.
    bool start();
    void stop();

    uint32_t id() const { return m_id; }
    // now is a monotonic time in seconds (also stamped into the packet).
    void send(const NetPose& pose, double now);
    // Drains incoming packets.
    void poll(double now);
    // Everyone heard from recently, interpolated, ordered by id.
    std::vector<RemotePlayer> sample(double now);

private:
    struct Snapshot
    {
        double sendTime;
        NetPose pose;
    };
    struct Peer
    {
        sockaddr_in addr{};
        std::vector<Snapshot> snapshots; // oldest first, by send time
        std::vector<double> offsets;     // recent arrival - send times
        double lastHeard = 0;
        uint32_t lastSeq = 0;
        // Arrival stats, logged every few seconds.
        int received = 0;
        double maxGap = 0;
        double lastArrival = 0;
        double statsStart = 0;
    };

    int m_socket = -1;
    uint32_t m_id = 0;
    uint32_t m_seq = 0;
    uint32_t m_broadcastAddr = 0; // network byte order
    double m_lastHello = 0;
    std::map<uint32_t, Peer> m_peers;
};
