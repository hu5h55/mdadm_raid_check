#!/bin/bash

################################################################################
# RAID Health Monitor
# Version: 14.1 - Optimized (zero-fork inner loops, syntax fixed)
################################################################################

set -euo pipefail

# Matte colors
readonly C_RED='\e[38;5;203m'
readonly C_GREEN='\e[38;5;150m'
readonly C_YELLOW='\e[38;5;221m'
readonly C_BLUE='\e[38;5;111m'
readonly C_CYAN='\e[38;5;117m'
readonly C_MAGENTA='\e[38;5;183m'
readonly C_GRAY='\e[38;5;245m'
readonly C_WHITE='\e[38;5;255m'
readonly RESET='\e[0m'

PATH=/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin

################################################################################
# Helpers
################################################################################

# Pure-bash trim — no sed fork; works both as pipe filter and with args
trim() {
    local s
    if [[ $# -gt 0 ]]; then
        s="$*"
    else
        IFS= read -r -d '' s || true
    fi
    s="${s#"${s%%[! $'\t']*}"}"
    s="${s%"${s##*[! $'\t']}"}"
    printf '%s' "$s"
}

check_deps() {
    local cmd
    for cmd in mdadm parted smartctl lsblk; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: Missing $cmd" >&2
            exit 1
        fi
    done
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${C_RED}ERROR: Root privileges are required to read SMART data and RAID status.${RESET}" >&2
        echo -e "Please re-run with: ${C_WHITE}sudo $0${RESET}\n" >&2
        exit 1
    fi
}

kb_to_human() {
    local kb=$1
    if [[ $kb -gt 1073741824 ]]; then
        awk "BEGIN {printf \"%.2f TiB\", $kb/1073741824}"
    elif [[ $kb -gt 1048576 ]]; then
        awk "BEGIN {printf \"%.2f GiB\", $kb/1048576}"
    else
        awk "BEGIN {printf \"%.2f MiB\", $kb/1024}"
    fi
}

################################################################################
# Info Gathering
################################################################################

# Single awk pass over mdstat
get_raids() {
    awk -F' :' '/^md[0-9]/ {print "/dev/"$1}' /proc/mdstat 2>/dev/null || true
}

# Single-awk — no double pipe
get_all_devs() {
    parted -l 2>&1 \
        | awk '/\/dev\//{split($2,a,":");if(a[1]!="Error")print a[1]}' \
        || true
}

get_disk_info() {
    local pattern=$1 parted_out=$2

    echo "$parted_out" \
        | grep -B1 -E '/dev/[cs]' \
        | grep -v -E '(--|Warning|Error|read-only)' \
        | sed -e 's/://g' -e 's/Array//g' | sed '/^\s*$/d' \
        | awk 'NR%2==1{gsub(" ","-");print} NR%2==0{print}' \
        | awk -v OFS=' ' '{
            if(NR%2==1) print $0
            else {
                dev_name = substr($2, 6)
                cmd = "cat /sys/block/" dev_name "/queue/rotational 2>/dev/null"
                rot = "UNK"
                if ((cmd | getline out) > 0) rot = out
                close(cmd)
                type = (rot == "1") ? "HDD" : (rot == "0") ? "SSD" : "UNK"
                print $2, $3, type
            }
        }' \
        | sed 'N;s/\n/ /' | sed 's/Model-//g' \
        | grep -E "$pattern" || true
}

# Single awk pass over smartctl output — replaces 5 grep|awk|head pipelines
get_error_info() {
    local pattern=$1 devs=$2
    grep -E "$pattern" <<< "$devs" | while read -r dev; do
        local smart_out
        smart_out=$(smartctl --all "$dev" 2>/dev/null || true)

        awk '
            /[Tt]emperature_[Cc]elsius/    && !t { temp=$10;         t=1 }
            /[Oo]ffline_[Uu]ncorrectable/ && !u { uncorr=$10;        u=1 }
            /[Cc]urrent_[Pp]ending_[Ss]ector/ && !p { pend=$10;      p=1 }
            /[Rr]eallocated_[Ss]ector_[Cc]t/  && !r { realloc=$10;   r=1 }
            /[Pp]ower_[Oo]n_[Hh]ours|Power On Hours/ && !h { poh=$NF; gsub(/,/,"",poh); h=1 }
            /^Serial Number:/              && !s { serial=$NF;        s=1 }
            END {
                    print (p ? pend   : 0) "|" \
                          (u ? uncorr : 0) "|" \
                          (p ? pend   : 0) "|" \
                          (r ? realloc: 0) "|" \
                          (h ? poh    : 0) "|" \
                          (s ? serial : "UNK")
            }
        ' <<< "$smart_out"
    done
}

# Native bash substitution instead of tr and sed subshells
filter_devs() {
    local devs=$1 remove=$2
    local pattern="${remove//$'\n'/|}"
    pattern="${pattern// /|}"
    pattern="${pattern%|}"
    [[ -n "$pattern" ]] && devs=$(grep -vE "$pattern" <<< "$devs" || true)
    echo "$devs"
}

################################################################################
# Display Functions
################################################################################

show_raid() {
    local md="$1" info="$2"

    local level total active state size_kb size mismatch df_line usage
    level=$(grep "Raid Level" <<< "$info"     | awk -F: '{print $2}' | trim || true)
    total=$(grep "Total Devices" <<< "$info"  | awk -F: '{print $2}' | trim || true)
    active=$(grep "Active Devices" <<< "$info"| awk -F: '{print $2}' | trim || true)
    state=$(grep "State :" <<< "$info"        | awk -F: '{print $2}' | trim || true)

    size_kb=$(grep "Array Size" <<< "$info" | grep -oP '\d+' | head -1 || true)
    size=$(kb_to_human "${size_kb:-0}")

    mismatch=0
    if [[ -f "/sys/block/${md:5}/md/mismatch_cnt" ]]; then
        mismatch=$(cat "/sys/block/${md:5}/md/mismatch_cnt" || echo 0)
    fi

    usage=""
    df_line=$(df -hP 2>/dev/null | grep "$md" | head -1 || true)

    if [[ -n "$df_line" ]]; then
        local pct used total_size bar_col
        pct=$(awk '{print $5}' <<< "$df_line" | tr -d '%' || true)

        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            used=$(awk '{print $3}' <<< "$df_line" || true)
            total_size=$(awk '{print $2}' <<< "$df_line" || true)

            local bar_width fill empty bar_fill bar_empty
            bar_width=10
            fill=$((pct * bar_width / 100))
            empty=$((bar_width - fill))

            bar_fill=$([[ $fill  -gt 0 ]] && printf '▰%.0s' $(seq 1 "$fill")  || true)
            bar_empty=$([[ $empty -gt 0 ]] && printf '▱%.0s' $(seq 1 "$empty") || true)

            bar_col=$C_GREEN
            if   [[ $pct -gt 80 ]]; then bar_col=$C_RED
            elif [[ $pct -gt 60 ]]; then bar_col=$C_YELLOW
            fi

            usage="${bar_col}${bar_fill}${C_GRAY}${bar_empty}${RESET} ${pct}% ${C_GRAY}(${used}/${total_size})${RESET}"
        fi
    fi

    local state_col=$C_GRAY
    local state_txt_upper="${state^^}"

    if   [[ "$state_txt_upper" == *"ACTIVE"* ]]; then state_col=$C_GREEN;  state_txt_upper="ACTIVE"
    elif [[ "$state_txt_upper" == *"CLEAN"* ]]; then state_col=$C_CYAN;   state_txt_upper="CLEAN"
    elif [[ "$state_txt_upper" == *"DEGRADED"* ]]; then state_col=$C_RED;    state_txt_upper="DEGRADED"
    fi

    local sync_str=""
    local md_short="${md##*/}"
    local sync_line
    sync_line=$(grep -A 2 "^${md_short} " /proc/mdstat 2>/dev/null | grep -E '(recovery|resync|check)' || true)

    if [[ -n "$sync_line" ]]; then
        local sync_pct sync_eta
        sync_pct=$(awk -F'=' '{print $2}' <<< "$sync_line" | awk '{print $1}' || true)
        sync_eta=$(awk -F'finish=' '{print $2}' <<< "$sync_line" | awk '{print $1}' || true)

        state_col=$C_YELLOW
        state_txt_upper="REBUILDING"
        sync_str="  ${C_GRAY}Sync:${RESET} ${C_YELLOW}${sync_pct} (${sync_eta})${RESET}"
    fi

    local mismatch_col=$C_GREEN
    [[ $mismatch -ne 0 ]] && mismatch_col=$C_RED

    local mnt_str=""
    if [[ -n "$df_line" ]]; then
        mnt_str=" ${C_GRAY}($(awk '{print $6}' <<< "$df_line"))${RESET}"
    fi

    local devs_txt="${active}/${total}"

    echo -e "${C_BLUE}■ ${level}${RESET}  ${C_BLUE}${md}${RESET}${mnt_str}    ${C_WHITE}${size}${RESET}"

    local anomaly=0
    [[ $mismatch -ne 0 ]]                  && anomaly=1
    [[ "$state_txt_upper" == "DEGRADED"   ]] && anomaly=1
    [[ "$state_txt_upper" == "REBUILDING" ]] && anomaly=1
    [[ "$active" != "$total" ]]              && anomaly=1

    if [[ $anomaly -eq 0 ]]; then
        echo -e -n "  ${state_col}${state_txt_upper}${RESET}    ${C_GRAY}${devs_txt} devices${RESET}"
        [[ -n "$usage" ]] && echo -e -n "    ${C_GRAY}Usage:${RESET} $usage"
        echo ""
    else
        echo -e "  ${state_col}${state_txt_upper}${RESET}"
        echo -e -n "  ${C_YELLOW}!${RESET}    ${C_GRAY}Mismatch: ${mismatch_col}${mismatch}${RESET}    ${C_GRAY}Active: ${C_WHITE}${devs_txt}${RESET}"
        [[ -n "$usage"    ]] && echo -e -n "    ${C_GRAY}Usage:${RESET} $usage"
        [[ -n "$sync_str" ]] && echo -e -n "$sync_str"
        echo ""
    fi
}

show_disks() {
    local pattern="$1" parted_out="$2" all_devs="$3" raid_info="${4:-}"

    printf "  \e[1m${C_WHITE}%-24s %-10s %-10s %-8s %-6s %-6s %-8s %-18s %s${RESET}\n" \
        "Model" "Device" "Serial" "Size" "Type" "POH" "Temp" "Errors" "State"

    local disk_info err_info states num
    disk_info=$(get_disk_info "$pattern" "$parted_out" || true)
    err_info=$(get_error_info "$pattern" "$all_devs"   || true)

    states=""
    if [[ -n "$raid_info" ]]; then
        states=$(grep -E "$pattern" <<< "$raid_info" | awk '{print $7"|"$6"|"$5}' | sort || true)
    fi

    num=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local err state model dev size type
        err=$(sed -n "${num}p" <<< "$err_info" || true)
        state=$(sed -n "${num}p" <<< "$states" || true)

        model=$(awk '{print $1}' <<< "$line" || true)
        dev=$(awk '{print $2}' <<< "$line" || true)
        size=$(awk '{print $3}' <<< "$line" || true)
        type=$(awk '{print $4}' <<< "$line" || true)

        [[ ${#model} -gt 23 ]] && model="${model:0:20}..."

        local temp uncorr pend realloc poh serial
        IFS='|' read -r temp uncorr pend realloc poh serial <<< "$err"

        [[ "$temp"    =~ ^[0-9]+$ ]] || temp=0
        [[ "$uncorr"  =~ ^[0-9]+$ ]] || uncorr=0
        [[ "$pend"    =~ ^[0-9]+$ ]] || pend=0
        [[ "$realloc" =~ ^[0-9]+$ ]] || realloc=0

        local poh_col=$C_GRAY poh_fmt="$poh"
        if [[ "$poh" =~ ^[0-9]+$ ]]; then
            poh_col=$C_GREEN
            (( poh > 50000 )) && poh_col=$C_RED   || \
            (( poh > 30000 )) && poh_col=$C_YELLOW
            (( poh > 1000  )) && poh_fmt="$((poh / 1000))k"
        fi

        local serial_fmt="$serial"
        [[ ${#serial_fmt} -gt 6 ]] && serial_fmt="..${serial_fmt: -6}"

        local type_col=$C_YELLOW
        [[ "$type" == "SSD" ]] && type_col=$C_CYAN

        local temp_col=$C_GRAY
        local temp_out
        temp_out=$(printf "%-8s" "N/A")
        if [[ "$temp" =~ ^[0-9]+$ ]] && (( temp > 0 )); then
            temp_col=$C_GREEN
            (( temp >= 50 )) && temp_col=$C_RED    || \
            (( temp >= 40 )) && temp_col=$C_YELLOW
            temp_out=$(printf "%-9s" "${temp}°C")
        fi

        local err_col=$C_GRAY err_str=""
        [[ $pend    -ne 0 ]] && err_str+="Pend:${pend} "
        [[ $uncorr  -ne 0 ]] && err_str+="Unc:${uncorr} "
        [[ $realloc -ne 0 ]] && err_str+="Realloc:${realloc} "

        if [[ -n "$err_str" ]]; then
            err_col=$C_RED
            err_str="${err_str% }"
        else
            err_str="-"
        fi

        local state_txt
        state_txt=$(awk -F'|' '{print $2" "$3}' <<< "$state" | trim || true)

        local state_col=$C_GRAY
        case "${state_txt}" in
            *faulty*|*fail*) state_col=$C_RED ;;
            *spare*)         state_col=$C_BLUE ;;
            *rebuild*|*recover*|*resync*) state_col=$C_YELLOW ;;
        esac

        local model_col=$C_WHITE
        if [[ "$poh_col"   == "$C_RED" || "$temp_col" == "$C_RED" ||
              "$err_col"   == "$C_RED" || "$state_col" == "$C_RED" ]]; then
            model_col=$C_RED
        fi

        printf "  ${model_col}%-24s${RESET} ${C_CYAN}%-10s${RESET} ${C_GRAY}%-10s${RESET} ${C_WHITE}%-8s${RESET} ${type_col}%-6s${RESET} ${poh_col}%-6s${RESET} ${temp_col}%s${RESET} ${err_col}%-18s${RESET} ${state_col}%s${RESET}\n" \
            "$model" "$dev" "$serial_fmt" "$size" "$type" "$poh_fmt" "$temp_out" "$err_str" "$state_txt"

        num=$((num + 1))
    done <<< "$disk_info"
}

################################################################################
# Main
################################################################################

main() {
    check_deps

    echo ""

    local raids all_devs parted_out non_raid
    raids=$(get_raids)
    all_devs=$(get_all_devs)
    parted_out=$(parted -l 2>&1 || true)
    non_raid="$all_devs"

    if [[ -n "$raids" ]]; then
        local md info raid_devs remove pattern
        for md in $raids; do
            info=$(mdadm --detail "$md" 2>/dev/null || true)
            [[ -z "$info" ]] && continue

            show_raid "$md" "$info"

            raid_devs=$(grep "Raid Devices" <<< "$info" | awk -F: '{print $2}' | trim || echo 0)
            raid_devs=$(tail -n "$raid_devs" <<< "$info" | grep '/dev/' | awk '{print $7}' || true)

            remove="${raid_devs//[0-9]/}"
            non_raid=$(filter_devs "$non_raid" "$remove")

            raid_devs=$(grep -v '/dev/md' <<< "$raid_devs" || true)
            pattern=$(echo "${raid_devs//[0-9]/}" | tr '\n' '|' | sed 's/.$//' || true)

            [[ -n "$pattern" ]] && show_disks "$pattern" "$parted_out" "$all_devs" "$info"

            echo ""
        done
    fi

    if [[ -n "$non_raid" ]]; then
        echo -e "${C_MAGENTA}■ Standalone Disks${RESET}"
        local pattern
        pattern=$(echo "${non_raid//[0-9]/}" | tr '\n' '|' | sed 's/.$//' || true)
        [[ -n "$pattern" ]] && show_disks "$pattern" "$parted_out" "$all_devs" ""
        echo ""
    fi

    echo -e "${C_GRAY}Last updated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"
}

main "$@"
