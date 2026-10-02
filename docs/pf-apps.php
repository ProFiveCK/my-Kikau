function pf_apps(): array {
    return [
        'mykikau' => [
            'name'     => 'myKikau',
            'tagline'  => 'Clean your Mac with confidence',
            'platform' => 'macOS utility',
            'version'  => '0.7.0',
            'license'  => 'GPL-3.0',
            'summary'  => 'A native macOS maintenance app for safe cleanup, complete uninstalls, duplicate and large-file review, and a live system dashboard. It previews everything first and moves deletions to the Trash rather than destroying them.',
            'specs'    => [
                'macOS 14 Sonoma or later',
                'Apple Silicon',
                '3.1 MB DMG',
                'Signed & notarized by Apple',
                'Open source (GPL-3.0)',
            ],
            'download_url'  => 'https://www.projectfive.co.ck/downloads/myKikau-0.7.0.dmg',
            'notes_url'     => 'https://github.com/ProFiveCK/my-Kikau/releases',
            'source_url'    => 'https://github.com/ProFiveCK/my-Kikau',
            'download_note' => 'Automatic updates are delivered through Sparkle. Full Disk Access is requested and explained on first launch.',
            'features' => [
                ['icon' => 'eye',       'title' => 'Preview before delete',    'body' => 'Review file paths, sizes, and protected items before anything moves to the Trash.'],
                ['icon' => 'trash',     'title' => 'Leftover-aware uninstall', 'body' => 'Removes the app bundle plus LaunchAgents, login items, and related files in your Library.'],
                ['icon' => 'activity',  'title' => 'Live system dashboard',    'body' => 'CPU, memory, disk, network, GPU, thermals, and battery metrics refreshed every two seconds.'],
                ['icon' => 'copy',      'title' => 'Duplicate finder',         'body' => 'Content-hash verification identifies real duplicates before you decide what to remove.'],
                ['icon' => 'folder',    'title' => 'Large-file review',        'body' => 'Find big items across Downloads, Documents, Desktop, Pictures, and Movies.'],
                ['icon' => 'file-text', 'title' => 'Local activity log',       'body' => 'Every action is written to ~/Library/Logs/myKikau/operations.log on your own machine.'],
            ],
            'trust' => [
                'title' => 'Safety guardrails',
                'body'  => 'myKikau avoids macOS system files and protects over 90 critical Apple bundle IDs including Finder, Dock, and System Settings. It also recognises endpoint-security agents such as CrowdStrike, SentinelOne, and Jamf so managed Macs stay protected.',
            ],
            'expectations' => [
                'Full Disk Access is requested and explained on first launch',
                'Cleanup and uninstall actions are previewed before execution',
                'Files are moved to the Trash, never silently destroyed',
                'Signed and notarized by Apple',
                'Source code is public and inspectable on GitHub',
            ],
        ],
    ];
}
