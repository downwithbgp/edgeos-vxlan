#!/bin/bash
# Structural checks for the Vyatta/EdgeOS configuration templates (U-TPL-*).
#
# These checks do not execute the configuration engine.  They pin the template
# contract the engine relies on, including the $VAR() value-reference form:
# in the engine a bare `$VAR(<path>)` is an existence test whose value is the
# node name (cstore-varref.cpp), so values must be referenced with a trailing
# `@` component such as `$VAR(../local-ip/@)`.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TPL="$ROOT/templates/interfaces/vxlan"
HELPER="$ROOT/src/vyatta-vxlan-addr"
PASS=0
FAIL=0

ck_file_has() { # ck_file_has <desc> <file> <fixed string>
    local desc=$1 file=$2 needle=$3
    if grep -qF -- "$needle" "$file"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (missing in $file: $needle)"
    fi
}

ck_file_lacks() { # ck_file_lacks <desc> <file> <fixed string>
    local desc=$1 file=$2 needle=$3
    if grep -qF -- "$needle" "$file"; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc (unexpected in $file: $needle)"
    else
        PASS=$((PASS + 1))
    fi
}

# Model of the engine's variable expansion, used to prove which string the
# helper receives: `$VAR(<path>)` yields the last path component (the node
# name) when the node exists, while `$VAR(<path>/@)` yields the node's value.
engine_varref() { # engine_varref <ref> <sibling-value> <current-value>
    local ref=$1 sibling=$2 current=$3 inner
    case "$ref" in
        *"\$VAR("*) inner=${ref#*\$VAR(}; inner=${inner%)} ;;
        *) inner=$ref ;;
    esac
    case "$inner" in
        '@') printf '%s' "$current" ;;
        */@) printf '%s' "$sibling" ;;
        *) printf '%s' "${inner##*/}" ;;
    esac
}

# ------------------------------------------------------------ endpoint defs
LOCAL_DEF="$TPL/node.tag/local-ip/node.def"
REMOTE_DEF="$TPL/node.tag/remote-ip/node.def"

ck_file_has "local-ip accepts both families" "$LOCAL_DEF" "type: ipv4,ipv6"
ck_file_has "remote-ip accepts both families" "$REMOTE_DEF" "type: ipv4,ipv6"
ck_file_has "local-ip warns through the family-aware probe" "$LOCAL_DEF" \
    "vyatta-vxlan-addr present"
ck_file_has "remote-ip checks its own value" "$REMOTE_DEF" \
    "check-endpoint remote \$VAR(@)"

# The remote-ip commit expression must reference the local-ip *value*; the
# bare form would pass the node name ("local-ip") to the helper instead.
ck_file_has "remote-ip commit check uses the local-ip value reference" \
    "$REMOTE_DEF" "check-endpoints '\$VAR(../local-ip/@)' '\$VAR(@)'"
ck_file_lacks "remote-ip commit check avoids the bare local-ip reference" \
    "$REMOTE_DEF" "\$VAR(../local-ip)'"

REF_L=$(sed -n "s/.*check-endpoints '\([^']*\)' '\([^']*\)'.*/\1/p" "$REMOTE_DEF" | head -1)
REF_R=$(sed -n "s/.*check-endpoints '\([^']*\)' '\([^']*\)'.*/\2/p" "$REMOTE_DEF" | head -1)
if [ -z "$REF_L" ] || [ -z "$REF_R" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: could not extract the check-endpoints references from $REMOTE_DEF"
else
    RESOLVED_L=$(engine_varref "$REF_L" "2001:db8:1::1" "")
    RESOLVED_R=$(engine_varref "$REF_R" "" "2001:db8:1::2")
    if [ "$RESOLVED_L" = "2001:db8:1::1" ] && [ "$RESOLVED_R" = "2001:db8:1::2" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: engine expansion of '$REF_L'/'$REF_R' resolved to '$RESOLVED_L'/'$RESOLVED_R'"
    fi
    if "$HELPER" check-endpoints "$RESOLVED_L" "$RESOLVED_R" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: helper rejected the configured sibling value pair"
    fi
    # Negative model: the original bare form must resolve to the node name and
    # must be rejected by the helper (the C-2 failure condition).
    BARE=$(engine_varref "\$VAR(../local-ip)" "" "")
    if [ "$BARE" = "local-ip" ] && ! "$HELPER" check-endpoints "$BARE" "$RESOLVED_R" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: bare reference model does not reproduce the node-name failure"
    fi
fi

# ------------------------------------------------------- mutating handlers
while IFS= read -r file; do
    rel=${file#"$TPL"/}
    while IFS= read -r line; do
        case "$line" in
            create:* | update:* | delete:* | end:*)
                case "$rel:$line" in
                    "node.def:end: /opt/vyatta/sbin/vyatta-vxlan \"\$COMMIT_ACTION\" \"\$VAR(@)\"")
                        PASS=$((PASS + 1))
                        ;;
                    *identity-matches*)
                        PASS=$((PASS + 1))
                        ;;
                    *)
                        FAIL=$((FAIL + 1))
                        echo "FAIL: unguarded handler in $rel: $line"
                        ;;
                esac
                ;;
        esac
    done <"$file"
done < <(find "$TPL" -name '*.def' | sort)

# ------------------------------------------------------------- MTU contract
ck_file_lacks "mtu declares no static default" "$TPL/node.tag/mtu/node.def" "default:"

# ------------------------------------------------------------ packaging entry
ck_file_has "the helper is packaged" "$ROOT/debian/edgeos-vxlan.install" \
    "src/vyatta-vxlan-addr opt/vyatta/sbin/"

echo "unit-templates: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
