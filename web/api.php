<?php
/**
 * uhm web API — single endpoint for the three panel tabs
 *
 * Every answer comes from uhmtool.sh, invoked through sudo. The web user
 * never reads or writes a root-owned file directly.
 *
 * Params:
 *   ?g=log&a=tail&pos=N&lines=N   Read the log from a byte offset
 *   ?g=log&a=grep&q=TERM          Full-log search
 *   ?g=log&a=status               uhmd service state
 *   ?g=acl&a=list                 Editable ACL files
 *   ?g=acl&a=read&name=NAME       ACL file content
 *   ?g=acl&a=write&name=NAME      ACL file content (POST body)
 *   ?g=report&a=mac&q=MAC         Per-MAC report across local sources
 *   ?g=report&a=grace             Grace period list
 *   ?g=report&a=consistency       Consistency check and totals
 *   ?g=report&a=search&q=QUERY    Search by IP or hostname
 *   ?g=unifi&a=ACTION             UniFi reports
 */

header('Content-Type: application/json');
header('Cache-Control: no-store');

define('UHM_TOOL', '/etc/uhm/tools/uhmtool.sh');
define('MAX_BODY_BYTES', 1048576);

$actions = [
    'log'    => ['tail', 'grep', 'status'],
    'acl'    => ['list', 'read', 'write'],
    'report' => ['mac', 'grace', 'consistency', 'search'],
    'unifi'  => ['status', 'authorized', 'vouchers', 'guests', 'unauthorized'],
];

function fail(string $message, int $code = 400): void {
    http_response_code($code);
    echo json_encode(['error' => $message]);
    exit;
}

$group  = $_GET['g'] ?? '';
$action = $_GET['a'] ?? '';

if (!isset($actions[$group]) || !in_array($action, $actions[$group], true)) {
    fail('unknown action');
}

// Arguments are passed as a separate argv entry each, never interpolated
// into a shell string, so a crafted value cannot reach the shell.
$args = [$group, $action];
$body = null;

switch ($group . ':' . $action) {
    case 'log:tail':
        $pos   = $_GET['pos'] ?? '0';
        $lines = $_GET['lines'] ?? '200';
        if (!ctype_digit((string) $pos))   { $pos = '0'; }
        if (!ctype_digit((string) $lines)) { $lines = '200'; }
        $args[] = $pos;
        $args[] = $lines;
        break;

    case 'log:grep':
    case 'report:mac':
    case 'report:search':
        $query = trim((string) ($_GET['q'] ?? ''));
        if ($query === '') {
            fail('empty search term');
        }
        $args[] = $query;
        break;

    case 'acl:read':
        $args[] = (string) ($_GET['name'] ?? '');
        break;

    case 'acl:write':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            fail('write requires POST', 405);
        }
        $body = file_get_contents('php://input', false, null, 0, MAX_BODY_BYTES + 1);
        if ($body === false) {
            fail('cannot read request body');
        }
        if (strlen($body) > MAX_BODY_BYTES) {
            fail('content too large', 413);
        }
        $args[] = (string) ($_GET['name'] ?? '');
        break;
}

$command = 'sudo -n ' . escapeshellcmd(UHM_TOOL);
foreach ($args as $arg) {
    $command .= ' ' . escapeshellarg($arg);
}

$descriptors = [
    0 => ['pipe', 'r'],
    1 => ['pipe', 'w'],
    2 => ['pipe', 'w'],
];
$process = proc_open($command, $descriptors, $pipes);
if (!is_resource($process)) {
    fail('cannot run uhmtool.sh', 500);
}

if ($body !== null) {
    fwrite($pipes[0], $body);
}
fclose($pipes[0]);

$stdout = stream_get_contents($pipes[1]);
fclose($pipes[1]);
fclose($pipes[2]);
proc_close($process);

$stdout = trim((string) $stdout);
if ($stdout === '' || json_decode($stdout) === null) {
    fail('uhmtool.sh returned no data', 500);
}

echo $stdout;
