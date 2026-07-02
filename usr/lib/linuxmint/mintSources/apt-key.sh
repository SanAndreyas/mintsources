#!/bin/bash
# apt-key-clone: A drop-in replacement for apt-key on Debian 13
# Maps legacy commands to all modern and legacy keyring directories.

# Strip up to two dashes to normalize (e.g., --list becomes list)
COMMAND="${1#-}"
COMMAND="${COMMAND#-}"

# Define all possible key locations to scan
SCAN_PATHS=(
    "/etc/apt/trusted.gpg"
    "/etc/apt/trusted.gpg.d"/*
    "/etc/apt/keyrings"/*
#    "/usr/share/keyrings"/*
)

case "$COMMAND" in
    list)
        for keyfile in "${SCAN_PATHS[@]}"; do
            # The [ -f ] check safely skips missing directories like /etc/apt/trusted.gpg
            [ -f "$keyfile" ] || continue
            if file "$keyfile" | grep -qi -E 'PGP|GPG'; then
                echo "--------------------------------------------------------"
                echo "Keyring: $keyfile"
                echo "--------------------------------------------------------"
                gpg --show-keys --with-fingerprint "$keyfile" 2>/dev/null
                echo ""
            fi
        done
        ;;
        
    add)
        if [ "$EUID" -ne 0 ]; then echo "ERROR: Root privileges required."; exit 1; fi
        FILE="$2"
        if [ -z "$FILE" ]; then echo "Usage: apt-key add <file>"; exit 1; fi

        # Capture file or STDIN
        TMP_INPUT=$(mktemp)
        if [ "$FILE" = "-" ]; then
            cat > "$TMP_INPUT"
        else
            cat "$FILE" > "$TMP_INPUT"
        fi
        
        # Extract the fingerprint to name the file safely
        FPR=$(gpg --show-keys --with-colons "$TMP_INPUT" 2>/dev/null | grep "^fpr:" | head -n 1 | cut -d: -f10)
        if [ -z "$FPR" ]; then
            echo "ERROR: Could not extract a valid GPG key."
            rm -f "$TMP_INPUT"
            exit 1
        fi

        # We save to trusted.gpg.d so the key is globally trusted, mimicking legacy apt-key behavior
        DEST="/etc/apt/trusted.gpg.d/imported-${FPR}.gpg"
        
        # Import to a temporary keyring, then export cleanly as a dearmored binary
        # This handles both ASCII (.asc) and binary (.gpg) files perfectly.
        TMP_RING=$(mktemp)
        gpg --no-default-keyring --keyring "$TMP_RING" --import "$TMP_INPUT" >/dev/null 2>&1
        gpg --no-default-keyring --keyring "$TMP_RING" --export > "$DEST"
        
        chmod 644 "$DEST"
        rm -f "$TMP_INPUT" "$TMP_RING" "${TMP_RING}~"
        echo "OK"
        ;;
        
    del)
        if [ "$EUID" -ne 0 ]; then echo "ERROR: Root privileges required."; exit 1; fi
        KEYID="$2"
        if [ -z "$KEYID" ]; then echo "Usage: apt-key del <keyid>"; exit 1; fi

        # Remove spaces in case the user passed a full fingerprint
        KEYID=$(echo "$KEYID" | tr -d ' ')
        FOUND=0

        for keyfile in "${SCAN_PATHS[@]}"; do
            [ -f "$keyfile" ] || continue
            
            # Check if the keyid exists in this specific keyring file
            if gpg --show-keys --with-colons "$keyfile" 2>/dev/null | grep -qF "${KEYID}"; then
                KEY_COUNT=$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null | grep -c "^pub:")
                
                if [ "$KEY_COUNT" -le 1 ]; then
                    # If it's the only key in the file, delete the file entirely
                    rm -f "$keyfile"
                else
                    # If it's a multi-key file, delete just the specific key
                    gpg --no-default-keyring --keyring "$keyfile" --batch --yes --delete-keys "$KEYID" >/dev/null 2>&1
                    rm -f "${keyfile}~" # Clean up GPG backup file
                fi
                FOUND=1
            fi
        done
        
        if [ $FOUND -eq 1 ]; then
            echo "OK"
        else
            echo "Warning: Key not found."
        fi
        ;;
        
    *)
        echo "Usage: apt-key {add <file> | del <keyid> | list}"
        exit 1
        ;;
esac
