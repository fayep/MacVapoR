// vaporprobe: a sampling profiler, and a CPU count to lie about, for a Windows game under Wine.
//
// Built as version.dll (most games load it) and put beside the game's exe; Wine loads it instead
// of its own when run with WINEDLLOVERRIDES=version=n,b. Its own functions pass through to Wine's.
// Settings, from the environment:
//
//   VAPOR_CPUS=N              the game is told it has N CPUs (GetSystemInfo, GetProcessAffinityMask)
//   VAPOR_PROFILE=C:\path     samples x86 call stacks into that file (see report.py)
//   VAPOR_PROFILE_HZ=1000     samples a second, per thread
//   VAPOR_PROFILE_THREADS=all every thread, not only the one that loaded the game
//   VAPOR_PROFILE_MONO=0      leave Mono alone: C# frames stay addresses
//
// A sampled thread is suspended only while its registers and stack are read. Nothing in that
// window takes a lock (the thread may hold the loader's or the heap's): module code is unwound
// from the module's own unwind tables, read in place, and code outside modules (Mono's JIT
// output) by its frame pointer. Names for C# methods come from Mono itself, as it compiles them.

#include <windows.h>
#include <tlhelp32.h>
#include <winternl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>

static void say(const char *fmt, ...) {
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    DWORD w;
    WriteFile(GetStdHandle(STD_ERROR_HANDLE), msg, n > 0 ? (DWORD)n : 0, &w, NULL);
}

// ------------------------------------------------------------------------------- CPU count

static DWORD g_cpus;   // 0: the truth
static void (WINAPI *real_GetSystemInfo)(LPSYSTEM_INFO);
static BOOL (WINAPI *real_GetProcessAffinityMask)(HANDLE, PDWORD_PTR, PDWORD_PTR);

static DWORD_PTR cpu_mask(void) { return g_cpus >= 64 ? ~(DWORD_PTR)0 : (((DWORD_PTR)1 << g_cpus) - 1); }

static void WINAPI hook_GetSystemInfo(LPSYSTEM_INFO si) {
    real_GetSystemInfo(si);
    if (si->dwNumberOfProcessors > g_cpus) si->dwNumberOfProcessors = g_cpus;
    si->dwActiveProcessorMask &= cpu_mask();
}

static BOOL WINAPI hook_GetProcessAffinityMask(HANDLE p, PDWORD_PTR process, PDWORD_PTR system) {
    BOOL ok = real_GetProcessAffinityMask(p, process, system);
    if (ok && process) *process &= cpu_mask();
    if (ok && system) *system &= cpu_mask();
    return ok;
}

// The exe's import slots for these, found by name, so whatever the loader put in them.
static int patch_imports(HMODULE exe) {
    BYTE *base = (BYTE *)exe;
    IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
    IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    int patched = 0;
    for (IMAGE_IMPORT_DESCRIPTOR *d = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); dir.Size && d->Name; d++) {
        if (lstrcmpiA((char *)(base + d->Name), "KERNEL32.dll")) continue;
        IMAGE_THUNK_DATA *names = (IMAGE_THUNK_DATA *)(base + d->OriginalFirstThunk);
        IMAGE_THUNK_DATA *slots = (IMAGE_THUNK_DATA *)(base + d->FirstThunk);
        for (; names->u1.AddressOfData; names++, slots++) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            const char *name = (char *)((IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData))->Name;
            void *to = !strcmp(name, "GetSystemInfo") ? (void *)hook_GetSystemInfo
                     : !strcmp(name, "GetProcessAffinityMask") ? (void *)hook_GetProcessAffinityMask : NULL;
            if (!to) continue;
            DWORD old;
            VirtualProtect(&slots->u1.Function, sizeof(void *), PAGE_READWRITE, &old);
            slots->u1.Function = (ULONG_PTR)to;
            VirtualProtect(&slots->u1.Function, sizeof(void *), old, &old);
            patched++;
        }
    }
    return patched;
}

// --------------------------------------------------------------------------------- modules

typedef struct {
    uint64_t base, end;
    const RUNTIME_FUNCTION *pdata;   // sorted by BeginAddress
    DWORD pdata_count;
    char path[MAX_PATH];
    BOOL written;
} module;

#define MAX_MODULES 512
static module g_modules[MAX_MODULES];
static int g_module_count;

// Rebuilt with every thread running (Toolhelp and module lists take locks).
static void refresh_modules(void) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    MODULEENTRY32 me = {0};
    me.dwSize = sizeof me;
    for (BOOL ok = Module32First(snap, &me); ok; ok = Module32Next(snap, &me)) {
        uint64_t base = (uint64_t)me.modBaseAddr;
        int i;
        for (i = 0; i < g_module_count && g_modules[i].base != base; i++) {}
        if (i < g_module_count || g_module_count == MAX_MODULES) continue;
        module *m = &g_modules[g_module_count];
        memset(m, 0, sizeof *m);
        m->base = base;
        m->end = base + me.modBaseSize;
        lstrcpynA(m->path, me.szExePath, sizeof m->path);
        BYTE *b = (BYTE *)base;
        IMAGE_NT_HEADERS64 *nt = (IMAGE_NT_HEADERS64 *)(b + ((IMAGE_DOS_HEADER *)b)->e_lfanew);
        if (nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC &&
            nt->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64) {
            IMAGE_DATA_DIRECTORY ex = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
            if (ex.Size) {
                m->pdata = (const RUNTIME_FUNCTION *)(b + ex.VirtualAddress);
                m->pdata_count = ex.Size / sizeof(RUNTIME_FUNCTION);
            }
        }
        g_module_count++;
    }
    CloseHandle(snap);
}

static module *module_at(uint64_t pc) {
    for (int i = 0; i < g_module_count; i++)
        if (pc >= g_modules[i].base && pc < g_modules[i].end) return &g_modules[i];
    return NULL;
}

static const RUNTIME_FUNCTION *function_at(const module *m, uint64_t pc) {
    DWORD rva = (DWORD)(pc - m->base), lo = 0, hi = m->pdata_count;
    while (lo < hi) {
        DWORD mid = (lo + hi) / 2;
        if (rva < m->pdata[mid].BeginAddress) hi = mid;
        else if (rva >= m->pdata[mid].EndAddress) lo = mid + 1;
        else return &m->pdata[mid];
    }
    return NULL;
}

// ------------------------------------------------------------------------------- unwinding

typedef struct { uint64_t rip, rsp, rbp, lo, hi; } frame;   // lo..hi: the thread's stack

static BOOL on_stack(const frame *f, uint64_t p, uint64_t n) { return p >= f->lo && p + n <= f->hi && !(p & 7); }

// One x64 function's prologue undone from its unwind codes, as far as rip, rsp and rbp go.
static BOOL unwind_x64(const module *m, const RUNTIME_FUNCTION *fn, frame *f) {
    uint64_t rva_in = f->rip - m->base;
    for (int chain = 0; chain < 8; chain++) {
        const BYTE *ui = (const BYTE *)(m->base + fn->UnwindData);
        BYTE flags = ui[0] >> 3, count = ui[2], fpreg = ui[3] & 15, fpoff = ui[3] >> 4;
        const uint16_t *codes = (const uint16_t *)(ui + 4);
        uint64_t offset_in = rva_in - fn->BeginAddress;
        for (int i = 0; i < count; i++) {
            BYTE at = codes[i] & 0xFF, op = (codes[i] >> 8) & 15, info = codes[i] >> 12;
            BOOL done = chain > 0 || offset_in >= at;   // this code's instruction has run
            switch (op) {
            case 0:   // UWOP_PUSH_NONVOL
                if (done) {
                    if (!on_stack(f, f->rsp, 8)) return FALSE;
                    if (info == 5) f->rbp = *(uint64_t *)f->rsp;
                    f->rsp += 8;
                }
                break;
            case 1:   // UWOP_ALLOC_LARGE
                if (info == 0) { if (done) f->rsp += 8 * (uint64_t)codes[i + 1]; i += 1; }
                else { if (done) f->rsp += (uint64_t)codes[i + 1] | ((uint64_t)codes[i + 2] << 16); i += 2; }
                break;
            case 2:   // UWOP_ALLOC_SMALL
                if (done) f->rsp += 8 * (uint64_t)info + 8;
                break;
            case 3:   // UWOP_SET_FPREG: rsp was made from the frame register (rbp, in practice)
                if (done && fpreg == 5) f->rsp = f->rbp - 16 * (uint64_t)fpoff;
                break;
            case 4:   // UWOP_SAVE_NONVOL
                if (done && info == 5 && on_stack(f, f->rsp + 8 * (uint64_t)codes[i + 1], 8))
                    f->rbp = *(uint64_t *)(f->rsp + 8 * (uint64_t)codes[i + 1]);
                i += 1;
                break;
            case 5:   // UWOP_SAVE_NONVOL_FAR
                if (done && info == 5) {
                    uint64_t at2 = f->rsp + ((uint64_t)codes[i + 1] | ((uint64_t)codes[i + 2] << 16));
                    if (on_stack(f, at2, 8)) f->rbp = *(uint64_t *)at2;
                }
                i += 2;
                break;
            case 8: i += 1; break;   // UWOP_SAVE_XMM128
            case 9: i += 2; break;   // UWOP_SAVE_XMM128_FAR
            case 10:                 // UWOP_PUSH_MACHFRAME: an interrupt frame
                if (done) {
                    uint64_t p = f->rsp + (info ? 8 : 0);
                    if (!on_stack(f, p, 40)) return FALSE;
                    f->rip = *(uint64_t *)p;
                    f->rsp = *(uint64_t *)(p + 24);
                    return TRUE;
                }
                break;
            default:
                break;
            }
        }
        if (!(flags & UNW_FLAG_CHAININFO)) break;
        fn = (const RUNTIME_FUNCTION *)(codes + ((count + 1) & ~1));
    }
    if (!on_stack(f, f->rsp, 8)) return FALSE;
    f->rip = *(uint64_t *)f->rsp;
    f->rsp += 8;
    return TRUE;
}

// The caller's frame: by unwind table in module code, else by frame pointer (Mono's JIT keeps one).
static BOOL step(frame *f) {
    module *m = module_at(f->rip);
    if (m && m->pdata) {
        const RUNTIME_FUNCTION *fn = function_at(m, f->rip);
        if (fn) return unwind_x64(m, fn, f);
        // A leaf function without unwind info: its return address is on top.
        if (!on_stack(f, f->rsp, 8)) return FALSE;
        f->rip = *(uint64_t *)f->rsp;
        f->rsp += 8;
        return TRUE;
    }
    if (!on_stack(f, f->rbp, 16) || f->rbp < f->rsp) return FALSE;
    uint64_t bp = f->rbp;
    f->rip = *(uint64_t *)(bp + 8);
    f->rbp = *(uint64_t *)bp;
    f->rsp = bp + 16;
    return TRUE;
}

// ------------------------------------------------------------------------------- sampling

typedef struct {
    DWORD tid;
    HANDLE h;
    uint64_t lo, hi;
} target;

#define MAX_TARGETS 256
#define MAX_DEPTH 48
static target g_targets[MAX_TARGETS];
static int g_target_count;
static DWORD g_main_tid, g_hz = 1000;
static BOOL g_all_threads, g_mono = TRUE;
static char g_out_path[MAX_PATH];
static HANDLE g_out;
static char g_buf[1 << 20];
static size_t g_len;

typedef NTSTATUS (NTAPI *nqit_fn)(HANDLE, THREADINFOCLASS, PVOID, ULONG, PULONG);
typedef struct { NTSTATUS ExitStatus; PVOID TebBaseAddress; CLIENT_ID ClientId; KAFFINITY AffinityMask; LONG Priority; LONG BasePriority; } basic_thread_info;

static void add_target(DWORD tid) {
    for (int i = 0; i < g_target_count; i++) if (g_targets[i].tid == tid) return;
    if (g_target_count == MAX_TARGETS || tid == GetCurrentThreadId()) return;
    HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, tid);
    if (!h) return;
    static nqit_fn nqit;
    if (!nqit) nqit = (nqit_fn)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQueryInformationThread");
    basic_thread_info bi = {0};
    if (!nqit || nqit(h, 0 /* ThreadBasicInformation */, &bi, sizeof bi, NULL) || !bi.TebBaseAddress) { CloseHandle(h); return; }
    NT_TIB *tib = (NT_TIB *)bi.TebBaseAddress;
    g_targets[g_target_count++] = (target){tid, h, (uint64_t)tib->StackLimit, (uint64_t)tib->StackBase};
}

static void refresh_targets(void) {
    if (!g_all_threads) { add_target(g_main_tid); return; }
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    THREADENTRY32 te = {0};
    te.dwSize = sizeof te;
    DWORD pid = GetCurrentProcessId();
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te))
        if (te.th32OwnerProcessID == pid) add_target(te.th32ThreadID);
    CloseHandle(snap);
}

static void out_flush(void) {
    DWORD w;
    if (g_len) WriteFile(g_out, g_buf, (DWORD)g_len, &w, NULL);
    g_len = 0;
}

static void out(const char *fmt, ...) {
    if (g_len > sizeof g_buf - 4096) out_flush();
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(g_buf + g_len, sizeof g_buf - g_len, fmt, ap);
    va_end(ap);
    if (n > 0) g_len += n;
}

static void sample(target *t) {
    uint64_t pcs[MAX_DEPTH];
    int n = 0;
    CONTEXT c = {0};
    c.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
    if (SuspendThread(t->h) == (DWORD)-1) return;
    if (GetThreadContext(t->h, &c)) {
        frame f = {c.Rip, c.Rsp, c.Rbp, t->lo, t->hi};
        pcs[n++] = f.rip;
        while (n < MAX_DEPTH && step(&f) && f.rip > 0x10000) pcs[n++] = f.rip;
    }
    ResumeThread(t->h);
    if (!n) return;
    out("s %lx", t->tid);
    for (int i = 0; i < n; i++) {
        out(" %llx", (unsigned long long)pcs[i]);
    }
    out("\n");
}

// Mono, if the game has it: a profiler of ours that it calls as it finishes compiling each
// method, on the compiling thread (Mono's own), with the method's code range and name. The
// sampler never calls into Mono: Mono asserts on threads it doesn't expect.
typedef void *(*mono_ptr_fn)(void *);
static struct {
    mono_ptr_fn method_start, method_get;
    int (*code_size)(void *);
    char *(*full_name)(void *, int);
    void (*free_)(void *);
    BOOL installed;
} mono;
static CRITICAL_SECTION g_mono_lock;
static char g_mono_buf[4 << 20];
static size_t g_mono_len;
static int g_mono_dummy;   // the MonoProfiler handle: Mono only passes it back

static void jit_end(void *prof, void *method, void *ji, int result) {
    (void)prof;
    if (result != 0 || !ji) return;   // MONO_PROFILE_OK
    uint64_t start = (uint64_t)mono.method_start(ji), size = (uint64_t)mono.code_size(ji);
    char *name = mono.full_name(method, 1);
    EnterCriticalSection(&g_mono_lock);
    if (g_mono_len < sizeof g_mono_buf - 1024) {
        int n = snprintf(g_mono_buf + g_mono_len, 1024, "mono %llx %llx %s\n", (unsigned long long)start,
                         (unsigned long long)size, name ? name : "?");
        if (n > 0) g_mono_len += n < 1024 ? (size_t)n : 1023;
    }
    LeaveCriticalSection(&g_mono_lock);
    if (name && mono.free_) mono.free_(name);
}

static void hook_mono(void) {
    if (!g_mono || mono.installed) return;
    HMODULE m = GetModuleHandleA("mono.dll");
    if (!m) m = GetModuleHandleA("mono-2.0-bdwgc.dll");
    if (!m) return;
    void (*install)(void *, void *) = (void *)GetProcAddress(m, "mono_profiler_install");
    void (*install_jit_end)(void *) = (void *)GetProcAddress(m, "mono_profiler_install_jit_end");
    void (*set_events)(int) = (void *)GetProcAddress(m, "mono_profiler_set_events");
    mono.method_start = (mono_ptr_fn)GetProcAddress(m, "mono_jit_info_get_code_start");
    mono.code_size = (void *)GetProcAddress(m, "mono_jit_info_get_code_size");
    mono.full_name = (void *)GetProcAddress(m, "mono_method_full_name");
    mono.free_ = (void *)GetProcAddress(m, "g_free");
    if (!mono.free_) mono.free_ = (void *)GetProcAddress(m, "mono_free");
    mono.installed = TRUE;
    if (!install || !install_jit_end || !set_events || !mono.method_start || !mono.code_size || !mono.full_name) {
        say("vaporprobe: this Mono has no JIT profiler hooks; C# frames stay addresses\n");
        return;
    }
    install(&g_mono_dummy, NULL);
    install_jit_end((void *)jit_end);
    set_events(1 << 4);   // MONO_PROFILE_JIT_COMPILATION
    say("vaporprobe: naming C# methods as Mono compiles them\n");
}

static void flush_mono(void) {
    if (!mono.installed) return;
    EnterCriticalSection(&g_mono_lock);
    DWORD w;
    if (g_mono_len) WriteFile(g_out, g_mono_buf, (DWORD)g_mono_len, &w, NULL);
    g_mono_len = 0;
    LeaveCriticalSection(&g_mono_lock);
}

static DWORD WINAPI sampler(void *unused) {
    (void)unused;
    Sleep(200);   // past the loader
    g_out = CreateFileA(g_out_path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_out == INVALID_HANDLE_VALUE) { say("vaporprobe: can't write %s\n", g_out_path); return 0; }
    out("vaporprobe 1\nmain %lx\nhz %lu\ncpus %lu\n", g_main_tid, g_hz, g_cpus);
    timeBeginPeriod(1);
    DWORD period = g_hz >= 1000 ? 1 : 1000 / g_hz, last = 0;
    unsigned long long samples = 0;
    for (;;) {
        DWORD now = GetTickCount();
        if (now - last >= 1000) {   // once a second, with every thread running
            refresh_modules();
            for (int i = 0; i < g_module_count; i++)
                if (!g_modules[i].written) {
                    out("module %llx %llx %s\n", (unsigned long long)g_modules[i].base,
                        (unsigned long long)(g_modules[i].end - g_modules[i].base), g_modules[i].path);
                    g_modules[i].written = TRUE;
                }
            refresh_targets();
            hook_mono();
            out("t %lu %llu\n", now, samples);
            out_flush();
            flush_mono();
            last = now;
        }
        for (int i = 0; i < g_target_count; i++) {
            sample(&g_targets[i]);
            samples++;
        }
        Sleep(period);
    }
    return 0;
}

// ------------------------------------------------------------------------------- version.dll

static HMODULE g_real;
#define FUNCTIONS(X) X(GetFileVersionInfoA) X(GetFileVersionInfoW) X(GetFileVersionInfoExA) X(GetFileVersionInfoExW) \
    X(GetFileVersionInfoSizeA) X(GetFileVersionInfoSizeW) X(GetFileVersionInfoSizeExA) X(GetFileVersionInfoSizeExW) \
    X(VerFindFileA) X(VerFindFileW) X(VerInstallFileA) X(VerInstallFileW) X(VerLanguageNameA) X(VerLanguageNameW) \
    X(VerQueryValueA) X(VerQueryValueW)
#define POINTER(name) void *real_##name;
FUNCTIONS(POINTER)
#define THUNK(name) __asm__(".globl " #name "\n" #name ":\n jmp *real_" #name "(%rip)\n");
FUNCTIONS(THUNK)

static DWORD env_number(const char *name, DWORD dflt) {
    char buf[32];
    return GetEnvironmentVariableA(name, buf, sizeof buf) ? strtoul(buf, NULL, 10) : dflt;
}

BOOL WINAPI DllMain(HINSTANCE self, DWORD why, LPVOID reserved) {
    (void)self; (void)reserved;
    if (why == DLL_PROCESS_DETACH && g_out) { out_flush(); return TRUE; }
    if (why != DLL_PROCESS_ATTACH) return TRUE;
    char path[MAX_PATH];
    GetSystemDirectoryA(path, sizeof path);
    lstrcatA(path, "\\version.dll");
    g_real = LoadLibraryA(path);
    if (!g_real) { say("vaporprobe: no system version.dll\n"); return FALSE; }
#define LOOKUP(name) real_##name = (void *)GetProcAddress(g_real, #name);
    FUNCTIONS(LOOKUP)

    g_main_tid = GetCurrentThreadId();   // the loader runs on the game's first thread
    g_cpus = env_number("VAPOR_CPUS", 0);
    if (g_cpus) {
        HMODULE k32 = GetModuleHandleA("kernel32.dll");
        real_GetSystemInfo = (void *)GetProcAddress(k32, "GetSystemInfo");
        real_GetProcessAffinityMask = (void *)GetProcAddress(k32, "GetProcessAffinityMask");
        int n = patch_imports(GetModuleHandleA(NULL));
        char buf[16];
        snprintf(buf, sizeof buf, "%lu", g_cpus);
        SetEnvironmentVariableA("NUMBER_OF_PROCESSORS", buf);
        say("vaporprobe: %lu CPUs (%d imports rewritten)\n", g_cpus, n);
    }
    if (GetEnvironmentVariableA("VAPOR_PROFILE", g_out_path, sizeof g_out_path)) {
        g_hz = env_number("VAPOR_PROFILE_HZ", 1000);
        if (!g_hz) g_hz = 1000;
        char buf[16];
        g_all_threads = GetEnvironmentVariableA("VAPOR_PROFILE_THREADS", buf, sizeof buf) && !lstrcmpiA(buf, "all");
        g_mono = env_number("VAPOR_PROFILE_MONO", 1) != 0;
        InitializeCriticalSection(&g_mono_lock);
        CloseHandle(CreateThread(NULL, 0, sampler, NULL, 0, NULL));
        say("vaporprobe: profiling %s at %lu Hz into %s\n", g_all_threads ? "every thread" : "the main thread", g_hz, g_out_path);
    }
    return TRUE;
}
