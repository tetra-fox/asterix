# Resource use of Asterisk and of the host for the load tests in
# ../stress.nix, and SIPp's statistics. Test scripts read it after phone.py,
# whose imports and journal helpers it uses.
import csv
import io
import os

USAGE_SCRIPT = r"""
pid=$(systemctl show -P MainPID asterisk.service)
echo "pid $pid"
awk '/^VmRSS/ {print "rss_kib", $2} /^Threads/ {print "threads", $2}' /proc/$pid/status
echo "fds $(ls /proc/$pid/fd | wc -l)"
# utime and stime in clock ticks of 1/100 s; the command name has no spaces
awk '{print "cpu_s", ($14 + $15) / 100}' /proc/$pid/stat
# the words are singular for 1: 1 active call
asterisk -rx 'core show channels count' | awk '/active channels?$/ {print "channels", $1} /active calls?$/ {print "calls", $1} /calls? processed$/ {print "processed", $1}'
echo "bridges $(asterisk -rx 'bridge show all' | tail -n +2 | grep -c .)"
asterisk -rx 'core show taskprocessors' | awk '/^[0-9]+ taskprocessors$/ {print "taskprocessors", $1}'
asterisk -rx 'database show' | awk '/results found/ {print "astdb_entries", $1}'
echo "astdb_bytes $(stat -c %s /var/lib/asterisk/astdb.sqlite3)"
echo "contacts $(asterisk -rx 'pjsip show contacts' | sed -n 's/^Objects found: //p')"
echo "log_dir_bytes $(du -sb /var/log/asterisk | cut -f1)"
find /var/log/asterisk -maxdepth 1 -type f -printf 'log_%f_bytes %s\n'
# without what heap_in_use() has Asterisk print
echo "journal_bytes $(journalctl -u asterisk.service -o cat | grep -vE '^(Arena [0-9]+:|Total \(incl\. mmap\):|(system|in use) bytes +=|max mmap (regions|bytes) +=)' | wc -c)"
echo "vm_load1 $(cut -d' ' -f1 /proc/loadavg)"
echo "vm_mem_available_kib $(awk '/^MemAvailable/ {print $2}' /proc/meminfo)"
"""


def usage(machine):
    """Asterisk's resident memory, descriptors, threads, CPU seconds, channels,
    calls, bridges, taskprocessors, astdb size, contacts, bytes under
    /var/log/asterisk, in each file there and in its journal, and the VM's
    load; `contacts` is empty without registrations and `bridges` counts
    every bridge, with the ones ConfBridge keeps."""
    values = {}
    for line in machine.succeed(USAGE_SCRIPT).splitlines():
        key, _, value = line.partition(" ")
        values[key] = float(value) if value and value.replace(".", "", 1).isdigit() else value
    values["host_load1"] = host_load()
    return values


def lasting_descriptors(machine):
    """Asterisk's open descriptors, the fewest of 5 counts 0.2 s apart: the
    connection of a remote console that just exited and the journal of an
    astdb write are open for a moment only."""
    return int(machine.succeed(
        "pid=$(systemctl show -P MainPID asterisk.service); "
        + "for i in 1 2 3 4 5; do ls /proc/$pid/fd | wc -l; sleep 0.2; done | sort -n | sed -n 1p"
    ))


def heap_in_use(machine):
    """KiB of Asterisk's heap in use, which malloc_stats() prints to its
    standard error when gdb calls it. Resident memory keeps what glibc once
    took from the system; this goes down again when Asterisk frees memory.
    gdb stops Asterisk for about half a second."""
    cursor = journal_cursor(machine)
    machine.succeed("gdb -p $(systemctl show -P MainPID asterisk.service) -batch -ex 'call (void) malloc_stats()' > /dev/null 2>&1")
    # the last block of malloc_stats() is the total over all arenas
    total = r"Total \(incl\. mmap\):\s+.*?system bytes\s+=\s+\d+\s+.*?in use bytes\s+=\s+(\d+)"
    deadline = time.time() + 10
    while not (found := re.findall(total, journal_since(machine, cursor), re.S)):
        assert time.time() < deadline, "no malloc_stats() in the journal"
        time.sleep(0.5)
    return int(found[-1]) // 1024


def host_load():
    """The host's one-minute load average: other builds share its CPUs, and
    a limit measured while they were busy is theirs, not Asterisk's."""
    return os.getloadavg()[0]


def sipp_injection(machine, path, rows):
    """A SIPp injection file of `rows`, whose lines SIPp's calls take in turn."""
    machine.succeed(f"printf '%s\\n' SEQUENTIAL {shlex.join(';'.join(row) for row in rows)} > {path}")


def sipp_statistics(machine, path):
    """The last line of a SIPp statistics file (-trace_stat -stf `path`), by
    column name."""
    rows = list(csv.DictReader(io.StringIO(machine.succeed(f"cat {path}")), delimiter=";"))
    return rows[-1]
