// Single-thread std threading stubs for the emscripten build, whose
// libc++ compiles <mutex>/<shared_mutex>/<thread> out. Jolt runs its
// single-thread job system here, so the locks are correct no-ops and a
// std::thread (never constructed on this path) traps rather than drop work.
#pragma once

#if defined(__EMSCRIPTEN__)

#include <cstddef>
#include <cstdlib>

namespace std {

class mutex {
public:
    mutex() = default;
    mutex(const mutex &) = delete;
    mutex &operator=(const mutex &) = delete;
    void lock() {}
    bool try_lock() { return true; }
    void unlock() {}
};

class recursive_mutex {
public:
    recursive_mutex() = default;
    recursive_mutex(const recursive_mutex &) = delete;
    recursive_mutex &operator=(const recursive_mutex &) = delete;
    void lock() {}
    bool try_lock() { return true; }
    void unlock() {}
};

class shared_mutex {
public:
    shared_mutex() = default;
    shared_mutex(const shared_mutex &) = delete;
    shared_mutex &operator=(const shared_mutex &) = delete;
    void lock() {}
    bool try_lock() { return true; }
    void unlock() {}
    void lock_shared() {}
    bool try_lock_shared() { return true; }
    void unlock_shared() {}
};

// lock_guard and unique_lock are generic RAII wrappers this libc++ keeps
// even without threads, so they are NOT stubbed here (doing so makes them
// ambiguous). Only the thread-gated types below are missing.

template <class M>
class shared_lock {
public:
    shared_lock() : m_(nullptr) {}
    explicit shared_lock(M &m) : m_(&m) { m_->lock_shared(); }
    ~shared_lock() {
        if (m_) m_->unlock_shared();
    }
    shared_lock(const shared_lock &) = delete;
    shared_lock &operator=(const shared_lock &) = delete;

private:
    M *m_;
};

class thread {
public:
    class id {};
    thread() noexcept = default;
    template <class F, class... Args>
    explicit thread(F &&, Args &&...) {
        // The web build must stay on the single-thread job system; a real
        // thread here would silently never run its work.
        abort();
    }
    thread(thread &&) noexcept = default;
    thread &operator=(thread &&) noexcept { return *this; }
    thread(const thread &) = delete;
    bool joinable() const noexcept { return false; }
    void join() {}
    void detach() {}
    id get_id() const noexcept { return {}; }
    static unsigned hardware_concurrency() noexcept { return 1; }
};

// The one-thread build never blocks or yields to another thread.
namespace this_thread {
inline thread::id get_id() noexcept { return {}; }
inline void yield() noexcept {}
template <class Duration>
inline void sleep_for(const Duration &) {}
} // namespace this_thread

} // namespace std

#endif // __EMSCRIPTEN__
