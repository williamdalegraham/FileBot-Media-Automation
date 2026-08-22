#!/usr/bin/env -S filebot -script

def preset = net.filebot.ui.rename.UserPresets.findResult { group ->
    group.list().find { p -> p.name == name }
}
if (preset == null) {
    die "Preset does not exist: $name"
}
log.fine "Run Preset: $preset"
rename(
    file: args,
    output: output,
    action: preset.action,
    conflict: conflict ?: 'skip',
    db: preset.database,
    format: preset.format,
    order: preset.sortOrder,
    strict: preset.matchMode ==~ /Strict/,
    lang: preset.language
)

