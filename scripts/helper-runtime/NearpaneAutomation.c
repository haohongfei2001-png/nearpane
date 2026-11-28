// Local entry points for the signed Nearpane bundle. No general-purpose Python CLI.
#include <Python.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void check(PyStatus status) {
    if (PyStatus_Exception(status)) Py_ExitStatusException(status);
}

static void set_path(PyConfig *config, wchar_t **field, const char *resources, const char *name) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/%s", resources, name) >= (int)sizeof(path)) exit(2);
    check(PyConfig_SetBytesString(config, field, path));
}

int main(int argc, char **argv) {
    const int probe = argc == 2 && strcmp(argv[1], "--self-check") == 0;
    const char *entry = NULL;
    if (argc >= 3 && strcmp(argv[1], "profile") == 0) entry = "Profile/profile-migration.py";
    if (argc == 3 && strcmp(argv[1], "workrect") == 0) entry = "WorkRect/window-management.py";
    if (!entry && !probe) return 2;

    char executable[PATH_MAX], resources[PATH_MAX];
    uint32_t capacity = sizeof(executable);
    if (_NSGetExecutablePath(executable, &capacity) != 0 || !realpath(executable, resources)) return 2;
    const char suffix[] = "/Contents/Helpers/NearpaneAutomation";
    size_t len = strlen(resources);
    if (len < sizeof(suffix) || strcmp(resources + len - strlen(suffix), suffix)) return 2;
    strcpy(resources + len - strlen(suffix), "/Contents/Resources");

    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    check(Py_PreInitialize(&pre));
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.site_import = 0;
    config.write_bytecode = 0;
    config.buffered_stdio = 0; // Host reads the supervisor's status while the process is live.
    config.parse_argv = 0;
    config.module_search_paths_set = 1;
    wchar_t *zip = NULL;
    set_path(&config, &zip, resources, "Automation/stdlib.zip");
    check(PyWideStringList_Append(&config.module_search_paths, zip));
    PyMem_RawFree(zip);
    set_path(&config, &config.home, resources, "Automation");
    check(PyConfig_SetBytesString(&config, &config.executable, executable));
    check(PyConfig_SetBytesArgv(&config, argc - 1, argv + 1));
    if (probe) {
        check(PyConfig_SetString(&config, &config.run_command,
            L"import argparse, fcntl, hashlib, json, os, pathlib, select, shutil, sqlite3, stat, subprocess, sys, tempfile, time, uuid\n"
            L"assert sys.flags.isolated and sys.flags.no_site and len(sys.path) == 1\n"
            L"assert 0 < time.clock_gettime(time.CLOCK_UPTIME_RAW) <= time.clock_gettime(time.CLOCK_UPTIME_RAW)\n"
            L"assert hashlib.sha256(b'').hexdigest().startswith('e3b0c442')\n"
            L"with sqlite3.connect(':memory:') as db: assert db.execute('select 58').fetchone() == (58,)\n"
            L"print(json.dumps(dict(runtime='NearpaneAutomation',python=sys.version.split()[0],sqlite=sqlite3.sqlite_version)))\n"));
    } else {
        set_path(&config, &config.run_filename, resources, entry);
    }
    check(Py_InitializeFromConfig(&config));
    PyConfig_Clear(&config);
    return Py_RunMain();
}
