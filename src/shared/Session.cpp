#include "Session.hpp"
#include "../core/PortalManager.hpp"
#include "../helpers/Log.hpp"

static int onCloseRequest(SDBusRequest* req) {
    Debug::log(TRACE, "[internal] Close Request {}", (void*)req);

    if (!req)
        return 0;

    req->onDestroy();
    req->object.release();

    return 0;
}

static const sdbus::InterfaceName SESSION_INTERFACE = sdbus::InterfaceName{"org.freedesktop.impl.portal.Session"};

// Close from the frontend, or the second half of closeDBusSession()
static bool onCloseSession(SDBusSession* sess) {
    Debug::log(TRACE, "[internal] Close Session {}", (void*)sess);

    if (!sess || sess->closed)
        return false;

    sess->closed = true;

    // destroy the object outside of its own method handler
    auto destroy = std::move(sess->onDestroy);
    g_pPortalManager->addTimer({0, [sess, destroy]() {
                                    sess->object.reset();
                                    if (destroy)
                                        destroy();
                                }});

    return true;
}

bool closeDBusSession(SDBusSession* sess) {
    if (!sess || sess->closed || !sess->object)
        return false;

    Debug::log(LOG, "[internal] Closing session {} from the portal side", sess->handle.c_str());

    try {
        sess->object->emitSignal("Closed").onInterface(SESSION_INTERFACE);
    } catch (std::exception& e) { Debug::log(ERR, "[internal] Couldn't emit Closed for session {}: {}", sess->handle.c_str(), e.what()); }

    return onCloseSession(sess);
}

std::unique_ptr<SDBusSession> createDBusSession(sdbus::ObjectPath handle) {
    Debug::log(TRACE, "[internal] Create Session {}", handle.c_str());

    std::unique_ptr<SDBusSession> pSession = std::make_unique<SDBusSession>();
    const auto                    PSESSION = pSession.get();

    pSession->handle = handle;
    pSession->object = sdbus::createObject(*g_pPortalManager->getConnection(), handle);

    pSession->object->addVTable(sdbus::registerMethod("Close").implementedAs([PSESSION]() { onCloseSession(PSESSION); }), sdbus::registerSignal("Closed"))
        .forInterface(SESSION_INTERFACE);

    return pSession;
}

std::unique_ptr<SDBusRequest> createDBusRequest(sdbus::ObjectPath handle) {
    Debug::log(TRACE, "[internal] Create Request {}", handle.c_str());

    std::unique_ptr<SDBusRequest> pRequest = std::make_unique<SDBusRequest>();
    const auto                    PREQUEST = pRequest.get();

    pRequest->object = sdbus::createObject(*g_pPortalManager->getConnection(), handle);

    pRequest->object->addVTable(sdbus::registerMethod("Close").implementedAs([PREQUEST]() { onCloseRequest(PREQUEST); })).forInterface("org.freedesktop.impl.portal.Request");

    return pRequest;
}