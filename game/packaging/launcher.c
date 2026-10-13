/* Build: gcc -municode -mwindows -static launcher.c payload.o -lshell32 -o HRKill.exe
 * payload.o must contain a ZIP as resource 101 RCDATA. The ZIP root must
 * contain HRKill.exe and all of its runtime dependencies (including the game).
 * Requires Windows PowerShell with Expand-Archive (Windows 10 or newer).
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define PAYLOAD_ID 101
#define ZIP_ENV L"HRKILL_LAUNCHER_ZIP"
#define RUNTIME_ENV L"HRKILL_LAUNCHER_RUNTIME"

static void show_error(const wchar_t *operation, DWORD code)
{
    wchar_t *detail = NULL;
    wchar_t message[2048];
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                   FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0,
                   (wchar_t *)&detail, 0, NULL);
    _snwprintf(message, sizeof(message) / sizeof(message[0]),
               L"职海杀启动器 / HRKill Launcher\n\n%ls\n\n"
               L"错误 / Error %lu: %ls", operation, (unsigned long)code,
               detail ? detail : L"未知错误 / Unknown error");
    message[sizeof(message) / sizeof(message[0]) - 1] = L'\0';
    MessageBoxW(NULL, message, L"职海杀 / HRKill", MB_OK | MB_ICONERROR);
    if (detail) LocalFree(detail);
}

static wchar_t *join_path(const wchar_t *directory, const wchar_t *name)
{
    size_t a = wcslen(directory), b = wcslen(name);
    int slash = a && directory[a - 1] != L'\\' && directory[a - 1] != L'/';
    wchar_t *result;
    if (a > SIZE_MAX / sizeof(wchar_t) - b - 2) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    result = malloc((a + b + 2) * sizeof(wchar_t));
    if (!result) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    memcpy(result, directory, a * sizeof(wchar_t));
    if (slash) result[a++] = L'\\';
    memcpy(result + a, name, (b + 1) * sizeof(wchar_t));
    return result;
}

/* Encode UTF-16LE bytes without a BOM, as required by -EncodedCommand. */
static wchar_t *encode_command(const wchar_t *script)
{
    static const wchar_t alphabet[] =
        L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *bytes = (const unsigned char *)script;
    size_t length = wcslen(script) * sizeof(wchar_t);
    size_t output_length = ((length + 2) / 3) * 4;
    wchar_t *output = malloc((output_length + 1) * sizeof(wchar_t));
    size_t i, j = 0;
    if (!output) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    for (i = 0; i < length; i += 3) {
        unsigned int value = (unsigned int)bytes[i] << 16;
        if (i + 1 < length) value |= (unsigned int)bytes[i + 1] << 8;
        if (i + 2 < length) value |= bytes[i + 2];
        output[j++] = alphabet[(value >> 18) & 63];
        output[j++] = alphabet[(value >> 12) & 63];
        output[j++] = i + 1 < length ? alphabet[(value >> 6) & 63] : L'=';
        output[j++] = i + 2 < length ? alphabet[value & 63] : L'=';
    }
    output[j] = L'\0';
    return output;
}

/* argv[0] has special Windows CRT rules: quotes group executable-name
 * characters; backslashes are literal. Keep every subsequent argument intact. */
static const wchar_t *original_arguments(void)
{
    const wchar_t *p = GetCommandLineW();
    int quoted = 0;
    while (*p == L' ' || *p == L'\t') ++p;
    while (*p) {
        if (*p == L'"') quoted = !quoted;
        else if (!quoted && (*p == L' ' || *p == L'\t')) break;
        ++p;
    }
    return p;
}

static wchar_t *make_command(const wchar_t *executable, const wchar_t *tail)
{
    size_t a = wcslen(executable), b = wcslen(tail);
    wchar_t *command;
    /* CreateProcessW's limit includes the terminating NUL. The tail supplies
     * its own leading space, so forwarded arguments are copied verbatim. */
    if (a + b + 3 > 32767) {
        SetLastError(ERROR_FILENAME_EXCED_RANGE);
        return NULL;
    }
    command = malloc((a + b + 3) * sizeof(wchar_t));
    if (!command) {
        SetLastError(ERROR_NOT_ENOUGH_MEMORY);
        return NULL;
    }
    command[0] = L'"';
    memcpy(command + 1, executable, a * sizeof(wchar_t));
    command[a + 1] = L'"';
    memcpy(command + a + 2, tail, (b + 1) * sizeof(wchar_t));
    return command;
}

static BOOL run_and_wait(const wchar_t *executable, wchar_t *command,
                         const wchar_t *directory, BOOL hidden, DWORD *exit_code)
{
    STARTUPINFOW startup;
    PROCESS_INFORMATION process;
    DWORD error = ERROR_SUCCESS;
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    if (hidden) {
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
    }
    if (!CreateProcessW(executable, command, NULL, NULL, FALSE,
                        CREATE_NO_WINDOW, NULL, directory, &startup, &process))
        return FALSE;
    CloseHandle(process.hThread);
    if (WaitForSingleObject(process.hProcess, INFINITE) != WAIT_OBJECT_0)
        error = GetLastError();
    else if (!GetExitCodeProcess(process.hProcess, exit_code))
        error = GetLastError();
    CloseHandle(process.hProcess);
    if (error) {
        SetLastError(error);
        return FALSE;
    }
    return TRUE;
}

/* Remove reparse points themselves; never recurse through junctions or links. */
static BOOL remove_tree(const wchar_t *path)
{
    DWORD attributes = GetFileAttributesW(path), error = ERROR_SUCCESS;
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
    }
    if ((attributes & FILE_ATTRIBUTE_DIRECTORY) &&
        !(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        WIN32_FIND_DATAW entry;
        wchar_t *pattern = join_path(path, L"*");
        HANDLE search;
        if (!pattern) return FALSE;
        search = FindFirstFileW(pattern, &entry);
        free(pattern);
        if (search == INVALID_HANDLE_VALUE) {
            error = GetLastError();
            if (error == ERROR_FILE_NOT_FOUND) error = ERROR_SUCCESS;
        } else {
            do {
                wchar_t *child;
                if (!wcscmp(entry.cFileName, L".") ||
                    !wcscmp(entry.cFileName, L"..")) continue;
                child = join_path(path, entry.cFileName);
                if (!child) {
                    if (!error) error = GetLastError();
                    continue;
                }
                if (!remove_tree(child) && !error) error = GetLastError();
                free(child);
            } while (FindNextFileW(search, &entry));
            if (GetLastError() != ERROR_NO_MORE_FILES && !error)
                error = GetLastError();
            FindClose(search);
        }
    }
    /* Do not change attributes through a reparse point. */
    if ((attributes & FILE_ATTRIBUTE_READONLY) &&
        !(attributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
        if (!SetFileAttributesW(path, attributes & ~FILE_ATTRIBUTE_READONLY) && !error)
            error = GetLastError();
    }
    if (attributes & FILE_ATTRIBUTE_DIRECTORY) {
        if (!RemoveDirectoryW(path) && !error) error = GetLastError();
    } else {
        if (!DeleteFileW(path) && !error) error = GetLastError();
    }
    if (error) SetLastError(error);
    return error == ERROR_SUCCESS;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous,
                   PWSTR ignored_command, int show)
{
    static const wchar_t script[] =
        L"$ErrorActionPreference='Stop'; try { "
        L"Expand-Archive -LiteralPath $env:HRKILL_LAUNCHER_ZIP "
        L"-DestinationPath $env:HRKILL_LAUNCHER_RUNTIME -Force; exit 0 "
        L"} catch { exit 1 }";
    wchar_t temp_path[MAX_PATH], temp_directory[MAX_PATH];
    wchar_t system_directory[MAX_PATH];
    wchar_t *zip = NULL, *runtime = NULL, *powershell = NULL, *game = NULL;
    wchar_t *encoded = NULL, *tail = NULL, *command = NULL;
    BOOL have_temp = FALSE;
    HANDLE file = INVALID_HANDLE_VALUE;
    HRSRC resource;
    HGLOBAL loaded;
    const BYTE *payload;
    DWORD size, written, exit_code = 1, length;
    const wchar_t *operation = L"无法初始化启动器 / Cannot initialize launcher";
    (void)previous; (void)ignored_command; (void)show;

    resource = FindResourceW(instance, MAKEINTRESOURCEW(PAYLOAD_ID), RT_RCDATA);
    if (!resource) goto failure;
    size = SizeofResource(instance, resource);
    if (!size) { SetLastError(ERROR_RESOURCE_DATA_NOT_FOUND); goto failure; }
    loaded = LoadResource(instance, resource);
    if (!loaded) goto failure;
    payload = LockResource(loaded);
    if (!payload) { SetLastError(ERROR_RESOURCE_DATA_NOT_FOUND); goto failure; }

    operation = L"无法创建临时目录 / Cannot create temporary directory";
    length = GetTempPathW(MAX_PATH, temp_path);
    if (!length) goto failure;
    if (length >= MAX_PATH) { SetLastError(ERROR_FILENAME_EXCED_RANGE); goto failure; }
    if (!GetTempFileNameW(temp_path, L"HRK", 0, temp_directory)) goto failure;
    /* GetTempFileNameW reserves a unique name with a placeholder file. */
    if (!DeleteFileW(temp_directory)) goto failure;
    if (!CreateDirectoryW(temp_directory, NULL)) goto failure;
    have_temp = TRUE;
    zip = join_path(temp_directory, L"payload.zip");
    runtime = join_path(temp_directory, L"runtime");
    if (!zip || !runtime) goto failure;

    operation = L"无法写入游戏资源 / Cannot write embedded game archive";
    file = CreateFileW(zip, GENERIC_WRITE, 0, NULL, CREATE_NEW,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) goto failure;
    while (size) {
        if (!WriteFile(file, payload, size, &written, NULL)) goto failure;
        if (!written) { SetLastError(ERROR_WRITE_FAULT); goto failure; }
        payload += written;
        size -= written;
    }
    if (!CloseHandle(file)) { file = INVALID_HANDLE_VALUE; goto failure; }
    file = INVALID_HANDLE_VALUE;

    operation = L"无法解压游戏（需要 Windows PowerShell Expand-Archive） / "
                L"Cannot extract game (Windows PowerShell Expand-Archive required)";
    length = GetSystemDirectoryW(system_directory, MAX_PATH);
    if (!length) goto failure;
    if (length >= MAX_PATH) { SetLastError(ERROR_FILENAME_EXCED_RANGE); goto failure; }
    powershell = join_path(system_directory, L"WindowsPowerShell\\v1.0\\powershell.exe");
    encoded = encode_command(script);
    if (!powershell || !encoded) goto failure;
    if (!SetEnvironmentVariableW(ZIP_ENV, zip) ||
        !SetEnvironmentVariableW(RUNTIME_ENV, runtime)) goto failure;
    tail = malloc((wcslen(encoded) + 64) * sizeof(wchar_t));
    if (!tail) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); goto failure; }
    wcscpy(tail, L" -NoLogo -NoProfile -NonInteractive -EncodedCommand ");
    wcscat(tail, encoded);
    command = make_command(powershell, tail);
    if (!command) goto failure;
    if (!run_and_wait(powershell, command, system_directory, TRUE, &exit_code))
        goto failure;
    if (exit_code) { SetLastError(ERROR_INVALID_DATA); goto failure; }
    free(command); command = NULL;
    SetEnvironmentVariableW(ZIP_ENV, NULL);
    SetEnvironmentVariableW(RUNTIME_ENV, NULL);

    operation = L"无法启动游戏 runtime\\HRKill.exe / Cannot start runtime\\HRKill.exe";
    game = join_path(runtime, L"HRKill.exe");
    if (!game) goto failure;
    command = make_command(game, original_arguments());
    if (!command) goto failure;
    if (!run_and_wait(game, command, runtime, FALSE, &exit_code)) goto failure;
    goto cleanup;

failure:
    show_error(operation, GetLastError());
    exit_code = 1;
cleanup:
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (have_temp && !remove_tree(temp_directory)) {
        show_error(L"无法清理临时游戏文件 / Cannot remove temporary game files",
                   GetLastError());
        if (!exit_code) exit_code = 1;
    }
    free(command);
    free(tail);
    free(encoded);
    free(game);
    free(powershell);
    free(runtime);
    free(zip);
    return (int)exit_code;
}
