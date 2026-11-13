#pragma once

#include "../includes.hpp"

#include <sdbus-c++/sdbus-c++.h>

struct SDBusSession {
    std::unique_ptr<sdbus::IObject> object;
    sdbus::ObjectPath               handle;
    std::function<void()>           onDestroy;
    bool                            closed = false;
};

struct SDBusRequest {
    std::unique_ptr<sdbus::IObject> object;
    sdbus::ObjectPath               handle;
    std::function<void()>           onDestroy;
};

std::unique_ptr<SDBusSession> createDBusSession(sdbus::ObjectPath handle);
std::unique_ptr<SDBusRequest> createDBusRequest(sdbus::ObjectPath handle);

// End a session from the portal side: emit impl.portal.Session::Closed (the frontend relays it to the app), then tear it down
// the same way Close does. Returns false if the session was already closed.
bool closeDBusSession(SDBusSession* sess);
