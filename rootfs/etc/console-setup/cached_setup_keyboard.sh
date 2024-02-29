#!/bin/sh

if [ -f /run/console-setup/keymap_loaded ]; then
    rm /run/console-setup/keymap_loaded
    exit 0
fi
kbd_mode '-a' < '/dev/tty1' 
kbd_mode '-a' < '/dev/tty2' 
kbd_mode '-a' < '/dev/tty3' 
kbd_mode '-a' < '/dev/tty4' 
kbd_mode '-a' < '/dev/tty5' 
kbd_mode '-a' < '/dev/tty6' 
loadkeys '/etc/console-setup/cached_ISO-8859-15_del.kmap.gz' > '/dev/null' 
