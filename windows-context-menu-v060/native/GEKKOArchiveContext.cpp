// GEKKO ARCHIVE V0.6.0 Alpha — ExplorerCommand native Windows 11 (x64)
// Un fichier/dossier sélectionné à la fois. Aucune opération de compression
// dans Explorer : on ne fait que déposer une commande locale pour le pont V0.5.
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <strsafe.h>
#include <tlhelp32.h>
#include <new>
#include <cwchar>
#include <string>
#include <atomic>

// Le SDK Windows declare deja DllGetClassObject et DllCanUnloadNow via STDAPI.
// Ne pas redeclarer ces fonctions avec __declspec(dllexport) : MSVC C2375.
// Pour la cible x64 de ce module, exporter les deux noms COM non decores.
#pragma comment(linker, "/EXPORT:DllGetClassObject")
#pragma comment(linker, "/EXPORT:DllCanUnloadNow")

static std::atomic<long> g_objects{0};

// GUID fixes : ils doivent correspondre EXACTEMENT à AppxManifest.xml.
static const CLSID CLSID_GekkoOpen = {0x348348c7,0xf21a,0x4d5f,{0x8e,0x16,0x35,0xc9,0xf5,0x52,0x12,0xd4}};
static const CLSID CLSID_GekkoZip = {0xf69bbece,0x46d2,0x4b63,{0xa9,0x28,0xfd,0xcd,0xef,0xde,0x9b,0x61}};
static const CLSID CLSID_Gekko7z = {0x70c82349,0xd338,0x4980,{0x8c,0x07,0xbf,0xa7,0x01,0x62,0xb2,0x97}};
static const CLSID CLSID_GekkoHere = {0xb3746af8,0x1dd0,0x439a,{0xa4,0xcd,0x0a,0x8b,0x96,0xbd,0xeb,0xfd}};
static const CLSID CLSID_GekkoFolder = {0x3c811319,0x10b0,0x40e2,{0xa0,0xf5,0x67,0x8f,0xef,0xb6,0x19,0x17}};

enum class Action { Open, Zip, SevenZip, ExtractHere, ExtractFolder };

static const CLSID& ClassId(Action a) {
    switch (a) {
    case Action::Open: return CLSID_GekkoOpen;
    case Action::Zip: return CLSID_GekkoZip;
    case Action::SevenZip: return CLSID_Gekko7z;
    case Action::ExtractHere: return CLSID_GekkoHere;
    default: return CLSID_GekkoFolder;
    }
}
static const wchar_t* Title(Action a) {
    switch (a) {
    case Action::Open: return L"Ouvrir avec GEKKO ARCHIVE";
    case Action::Zip: return L"Compresser en ZIP";
    case Action::SevenZip: return L"Compresser en 7z";
    case Action::ExtractHere: return L"Extraire ici";
    default: return L"Extraire vers un dossier";
    }
}
static const char* Token(Action a) {
    switch (a) {
    case Action::Open: return "open";
    case Action::Zip: return "zip";
    case Action::SevenZip: return "7z";
    case Action::ExtractHere: return "extractHere";
    default: return "extractFolder";
    }
}
// Les préférences sont propres à l'utilisateur. Le menu reste fonctionnel si
// le fichier n'a pas encore été créé par la nouvelle interface.
static const wchar_t* ConfigKey(Action a) {
    switch(a){
    case Action::Open: return L"open";
    case Action::Zip: return L"zip";
    case Action::SevenZip: return L"7z";
    case Action::ExtractHere: return L"extractHere";
    default: return L"extractFolder";
    }
}
static bool CommandEnabled(Action a){
    PWSTR local=nullptr;
    if(FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData,0,nullptr,&local)) || !local)
        return true; // Aucun blocage si le profil Windows n'est pas accessible.
    std::wstring config(local);
    CoTaskMemFree(local);
    config += L"\\GEKKO_ARCHIVE\\context_menu.ini";
    return GetPrivateProfileIntW(L"ContextMenu",ConfigKey(a),1,config.c_str())!=0;
}
static bool IsArchive(const std::wstring& name) {
    const wchar_t* ext = PathFindExtensionW(name.c_str());
    static const wchar_t* allowed[] = { L".zip",L".7z",L".rar",L".tar",L".gz",L".bz2",L".xz",L".zst",L".cab",L".iso",L".wim",L".arj" };
    for (auto e : allowed) if (_wcsicmp(ext, e) == 0) return true;
    return false;
}
static HRESULT Selection(IShellItemArray* items, std::wstring& path, bool& isDirectory) {
    if (!items) return E_INVALIDARG;
    DWORD count = 0;
    HRESULT hr = items->GetCount(&count);
    if (FAILED(hr)) return hr;
    if (count != 1) return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
    IShellItem* item = nullptr;
    hr = items->GetItemAt(0, &item);
    if (FAILED(hr)) return hr;
    PWSTR value = nullptr;
    hr = item->GetDisplayName(SIGDN_FILESYSPATH, &value);
    SFGAOF attrs = 0;
    if (SUCCEEDED(hr)) {
        HRESULT attrHr = item->GetAttributes(SFGAO_FOLDER, &attrs);
        if (FAILED(attrHr)) hr = attrHr;
    }
    if (SUCCEEDED(hr) && value) {
        path = value;
        isDirectory = (attrs & SFGAO_FOLDER) != 0;
    }
    if (value) CoTaskMemFree(value);
    item->Release();
    return hr;
}
static bool Supports(Action action, const std::wstring& path, bool folder) {
    if (action == Action::Zip || action == Action::SevenZip) return true;
    return !folder && IsArchive(path);
}
static HRESULT Utf8(const std::wstring& s, std::string& result) {
    if (s.find(L'\n') != std::wstring::npos || s.find(L'\r') != std::wstring::npos)
        return HRESULT_FROM_WIN32(ERROR_INVALID_NAME);
    if (s.size() > 32000) return HRESULT_FROM_WIN32(ERROR_FILENAME_EXCED_RANGE);
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.c_str(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
    if (!n) return HRESULT_FROM_WIN32(GetLastError());
    result.resize(n);
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.c_str(), static_cast<int>(s.size()), &result[0], n, nullptr, nullptr))
        return HRESULT_FROM_WIN32(GetLastError());
    return S_OK;
}
static HRESULT MakeDirectory(const std::wstring& dir) {
    if (CreateDirectoryW(dir.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS)
        return S_OK;
    return HRESULT_FROM_WIN32(GetLastError());
}
static bool IsGekkoRunning() {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W entry = {};
    entry.dwSize = sizeof(entry);
    bool found = false;
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (_wcsicmp(entry.szExeFile, L"gekko-archive.exe") == 0) {
                found = true;
                break;
            }
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return found;
}
static HRESULT SendToBridge(Action action, const std::wstring& path) {
    PWSTR appData = nullptr;
    HRESULT hr = SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &appData);
    if (FAILED(hr)) return hr;
    std::wstring dir = appData;
    CoTaskMemFree(appData);
    dir += L"\\GEKKO_ARCHIVE";
    hr = MakeDirectory(dir);
    if (FAILED(hr)) return hr;
    dir += L"\\shell_bridge";
    hr = MakeDirectory(dir);
    if (FAILED(hr)) return hr;
    GUID unique = {};
    hr = CoCreateGuid(&unique);
    if (FAILED(hr)) return hr;
    wchar_t uuid[40] = {};
    if (!StringFromGUID2(unique, uuid, ARRAYSIZE(uuid))) return E_FAIL;
    std::wstring stem = dir + L"\\shell-command-" + uuid;
    std::wstring tmp = stem + L".tmp";
    std::wstring ready = stem + L".txt";
    std::string encoded;
    hr = Utf8(path, encoded);
    if (FAILED(hr)) return hr;
    const std::string body = std::string(Token(action)) + "\n" + encoded + "\n";
    HANDLE file = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
    DWORD written = 0;
    BOOL ok = WriteFile(file, body.data(), static_cast<DWORD>(body.size()), &written, nullptr);
    DWORD error = ok && written == body.size() ? ERROR_SUCCESS : (ok ? ERROR_WRITE_FAULT : GetLastError());
    if (error == ERROR_SUCCESS && !FlushFileBuffers(file)) error = GetLastError();
    CloseHandle(file);
    if (error != ERROR_SUCCESS) { DeleteFileW(tmp.c_str()); return HRESULT_FROM_WIN32(error); }
    if (!MoveFileExW(tmp.c_str(), ready.c_str(), MOVEFILE_WRITE_THROUGH)) {
        error = GetLastError();
        DeleteFileW(tmp.c_str());
        return HRESULT_FROM_WIN32(error);
    }
    return S_OK;
}

class GekkoCommand final : public IExplorerCommand {
    std::atomic<ULONG> refs_{1};
    const Action action_;
public:
    explicit GekkoCommand(Action a): action_(a) { ++g_objects; }
    ~GekkoCommand() { --g_objects; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IExplorerCommand)) {
            *out = static_cast<IExplorerCommand*>(this); AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG left = --refs_; if (!left) delete this; return left;
    }
    HRESULT STDMETHODCALLTYPE GetTitle(IShellItemArray*, LPWSTR* title) override {
        if (!title) return E_POINTER;
        return SHStrDupW(Title(action_), title);
    }
    HRESULT STDMETHODCALLTYPE GetIcon(IShellItemArray*, LPWSTR* icon) override {
        if (!icon) return E_POINTER;
        *icon = nullptr; return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE GetToolTip(IShellItemArray*, LPWSTR* tip) override {
        if (!tip) return E_POINTER;
        *tip = nullptr; return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE GetCanonicalName(GUID* name) override {
        if (!name) return E_POINTER;
        *name = ClassId(action_); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override {
        if (!state) return E_POINTER;
        if (!CommandEnabled(action_)) { *state=ECS_HIDDEN; return S_OK; }
        // Le Shell peut interroger GetState sans fournir une selection exploitable.
        // Dans ce cas, ne PAS cacher silencieusement une commande de compression.
        // ZIP et 7z acceptent tout fichier : restent donc visibles sans I/O.
        if (action_ == Action::Zip || action_ == Action::SevenZip) {
            *state = ECS_ENABLED;
            return S_OK;
        }
        // Les commandes d'ouverture/extraction sont visibles mais inactives
        // si la selection n'est pas reconnue comme archive.
        *state = ECS_DISABLED;
        if (!items) return S_OK;
        DWORD count = 0;
        if (FAILED(items->GetCount(&count)) || count != 1) return S_OK;
        IShellItem* item = nullptr;
        if (FAILED(items->GetItemAt(0, &item)) || !item) return S_OK;
        PWSTR name = nullptr;
        const HRESULT hr = item->GetDisplayName(SIGDN_NORMALDISPLAY, &name);
        if (SUCCEEDED(hr) && name && IsArchive(name)) *state = ECS_ENABLED;
        if (name) CoTaskMemFree(name);
        item->Release();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Invoke(IShellItemArray* items, IBindCtx*) override {
        if (!CommandEnabled(action_)) return HRESULT_FROM_WIN32(ERROR_ACCESS_DISABLED_BY_POLICY);
        std::wstring path; bool folder = false;
        HRESULT hr = Selection(items, path, folder);
        if (FAILED(hr)) return hr;
        if (!Supports(action_, path, folder)) return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED);
        if (!IsGekkoRunning()) {
            MessageBoxW(nullptr, L"Lance GEKKO ARCHIVE avant d'utiliser cette commande.\n"
                L"Le logiciel doit rester ouvert pendant ce test Alpha.",
                L"GEKKO ARCHIVE", MB_OK | MB_ICONINFORMATION);
            return HRESULT_FROM_WIN32(ERROR_SERVICE_NOT_ACTIVE);
        }
        return SendToBridge(action_, path);
    }
    HRESULT STDMETHODCALLTYPE GetFlags(EXPCMDFLAGS* flags) override {
        if (!flags) return E_POINTER;
        *flags = ECF_DEFAULT; return S_OK;
    }
    HRESULT STDMETHODCALLTYPE EnumSubCommands(IEnumExplorerCommand** result) override {
        if (!result) return E_POINTER;
        *result = nullptr; return E_NOTIMPL;
    }
};

class GekkoClassFactory final : public IClassFactory {
    std::atomic<ULONG> refs_{1};
    Action action_;
public:
    explicit GekkoClassFactory(Action a):action_(a) { ++g_objects; }
    ~GekkoClassFactory() { --g_objects; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IClassFactory)) {
            *out = static_cast<IClassFactory*>(this); AddRef(); return S_OK;
        }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG left=--refs_; if(!left) delete this; return left; }
    HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID riid, void** result) override {
        if (outer) return CLASS_E_NOAGGREGATION;
        if (!result) return E_POINTER;
        *result = nullptr;
        auto* cmd = new (std::nothrow) GekkoCommand(action_);
        if (!cmd) return E_OUTOFMEMORY;
        HRESULT hr = cmd->QueryInterface(riid, result);
        cmd->Release(); return hr;
    }
    HRESULT STDMETHODCALLTYPE LockServer(BOOL lock) override {
        if (lock) ++g_objects; else --g_objects;
        return S_OK;
    }
};

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, void** result) {
    if (!result) return E_POINTER;
    *result = nullptr;
    static const Action choices[] = {Action::Open, Action::Zip, Action::SevenZip, Action::ExtractHere, Action::ExtractFolder};
    for (auto action : choices) {
        if (IsEqualCLSID(clsid, ClassId(action))) {
            auto* factory = new (std::nothrow) GekkoClassFactory(action);
            if (!factory) return E_OUTOFMEMORY;
            HRESULT hr = factory->QueryInterface(riid, result);
            factory->Release(); return hr;
        }
    }
    return CLASS_E_CLASSNOTAVAILABLE;
}
STDAPI DllCanUnloadNow(void) {
    return g_objects.load() == 0 ? S_OK : S_FALSE;
}
BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) { return TRUE; }
