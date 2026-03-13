#!/bin/bash

################################################################################
# RAID Health Monitor
# Version: 12.2 - Pure Text Layout (Strict Root Enforcement)
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

trim() { sed -e 's/^ *//g' -e 's/ *$//g'; }

check_deps() {
    # Hard stop if not running as root
    if [[ $EUID -ne 0 ]]; then
        echo -e "\n${C_RED}ERROR: Root privileges are required to read SMART data and RAID status.${RESET}" >&2
        echo -e "Please re-run with: ${C_WHITE}sudo $0${RESET}\n" >&2
        exit 1
    fi

    local cmd
    for cmd in mdadm parted smartctl lsblk tput; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${C_RED}ERROR: Missing required command: $cmd${RESET}" >&2
            exit 1
        fi
    done
}

hr() {
    local color="${1:-$C_GRAY}"
    local cols
    cols=$(tput cols 2>/dev/null || echo 130)
    printf "${color}%s${RESET}\n" "$(printf '%*s' "$cols" '' | sed 's/ /━

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

get_raids() { grep ':' /proc/mdstat 2>/dev/null | grep -v -E '(Personalities|unused|bitmap)' | awk -F' :' '{print "/dev/"$1}' || true; }

get_all_devs() { parted -l 2>&1 | grep '/dev/' | awk '{print $2}' | awk -F: '{print $1}' | grep -v Error || true; }

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

get_error_info() {
    local dev smart_out temp uncorr pend realloc poh serial
    echo "$2" | grep -E "$1" | while read -r dev; do
        smart_out=$(smartctl --all "$dev" 2>/dev/null || true)
        
        temp=$(echo "$smart_out" | grep -iE 'Temperature_Celsius' | awk '{print $10}' | head -1 || true)
        uncorr=$(echo "$smart_out" | grep -iE 'Offline_Uncorrectable' | awk '{print $10}' | head -1 || true)
        pend=$(echo "$smart_out" | grep -iE 'Current_Pending_Sector' | awk '{print $10}' | head -1 || true)
        realloc=$(echo "$smart_out" | grep -iE 'Reallocated_Sector_Ct' | awk '{print $10}' | head -1 || true)
        
        poh=$(echo "$smart_out" | grep -iE '(Power_On_Hours|Power On Hours)' | awk '{print $NF}' | tr -d ',' | head -1 || true)
        serial=$(echo "$smart_out" | grep -i '^Serial Number:' | awk '{print $NF}' || true)
        
        echo "${temp:-0}|${uncorr:-0}|${pend:-0}|${realloc:-0}|${poh:-0}|${serial:-UNK}"
    done
}

filter_devs() {
    local devs=$1 remove=$2 d
    while read -r d; do 
        if [[ -n "$d" ]]; then
            devs=$(echo "$devs" | grep -v "$d" || true)
        fi
    done <<< "$remove"
    echo "$devs"
}

################################################################################
# Display Functions
################################################################################

show_raid() {
    local md="$1" info="$2"
    
    local level total active state size_kb size mismatch df_line usage
    level=$(echo "$info" | grep "Raid Level" | awk -F: '{print $2}' | trim || true)
    total=$(echo "$info" | grep "Total Devices" | awk -F: '{print $2}' | trim || true)
    active=$(echo "$info" | grep "Active Devices" | awk -F: '{print $2}' | trim || true)
    state=$(echo "$info" | grep "State :" | awk -F: '{print $2}' | trim || true)
    
    size_kb=$(echo "$info" | grep "Array Size" | grep -oP '\d+' | head -1 || true)
    size=$(kb_to_human "${size_kb:-0}")
    
    mismatch=0
    if [[ -f "/sys/block/${md:5}/md/mismatch_cnt" ]]; then
        mismatch=$(cat "/sys/block/${md:5}/md/mismatch_cnt" || echo 0)
    fi
    
    usage=""
    df_line=$(df -hP 2>/dev/null | grep "$md" | head -1 || true)
    
    if [[ -n "$df_line" ]]; then
        local pct used total_size bar_width fill empty bar_fill bar_empty bar_col i
        pct=$(echo "$df_line" | awk '{print $5}' | tr -d '%' || true)
        
        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            used=$(echo "$df_line" | awk '{print $3}' || true)
            total_size=$(echo "$df_line" | awk '{print $2}' || true)
            
            bar_width=10
            fill=$((pct * bar_width / 100))
            empty=$((bar_width - fill))
            
            bar_fill=""
            for ((i=0; i<fill; i++)); do bar_fill+="▰"; done
            
            bar_empty=""
            for ((i=0; i<empty; i++)); do bar_empty+="▱
                bar_col=$C_RED
            elif [[ $pct -gt 60 ]]; then
                bar_col=$C_YELLOW
            fi
            
            usage="${bar_col}${bar_fill}${C_GRAY}${bar_empty}${RESET} ${pct}% ${C_GRAY}(${used}/${total_size})${RESET}"
        fi
    fi
    
    local state_col=$C_GRAY
    local state_txt_upper
    state_txt_upper=$(echo "$state" | tr '[:lower:]' '[:upper:]' || true)
    
    if [[ "$state_txt_upper" == *"ACTIVE"* ]]; then
        state_col=$C_GREEN
        state_txt_upper="ACTIVE"
    elif [[ "$state_txt_upper" == *"CLEAN"* ]]; then
        state_col=$C_CYAN
        state_txt_upper="CLEAN"
    elif [[ "$state_txt_upper" == *"DEGRADED"* ]]; then
        state_col=$C_RED
        state_txt_upper="DEGRADED"
    fi

    local sync_str=""
    local md_short="${md##*/}"
    local sync_line
    sync_line=$(grep -A 2 "^${md_short} " /proc/mdstat 2>/dev/null | grep -E '(recovery|resync|check)' || true)
    
    if [[ -n "$sync_line" ]]; then
        local sync_pct sync_eta
        sync_pct=$(echo "$sync_line" | awk -F'=' '{print $2}' | awk '{print $1}' || true)
        sync_eta=$(echo "$sync_line" | awk -F'finish=' '{print $2}' | awk '{print $1}' || true)
        
        state_col=$C_YELLOW
        state_txt_upper="REBUILDING"
        sync_str="  ${C_GRAY}Sync:${RESET} ${C_YELLOW}${sync_pct} (${sync_eta})${RESET}"
    fi
    
    local mismatch_col=$C_GREEN
    if [[ $mismatch -ne 0 ]]; then
        mismatch_col=$C_RED
    fi

    local mnt_str=""
    if [[ -n "$df_line" ]]; then
        mnt_str=" ${C_GRAY}($(echo "$df_line" | awk '{print $6}'))${RESET}"
    fi

    echo -e "${C_BLUE}${md}${mnt_str} - RAID ${level}${RESET}"
    hr "$C_BLUE"
    
    local devs_txt="${active}/${total}"
    
    # Grid-Aligned Metadata Output
    printf "  ${C_GRAY}Status: ${state_col}%-16s${RESET} ${C_GRAY}Devs: ${C_WHITE}%-
        
        local poh_col=$C_GREEN
        local poh_fmt
        if [[ "$poh" =~ ^[0-9]+$ ]]; then
            if [[ $poh -gt 50000 ]]; then
                poh_col=$C_RED
            elif [[ $poh -gt 30000 ]]; then
                poh_col=$C_YELLOW
            fi
            
            if [[ $poh -gt 1000 ]]; then
                poh_fmt="$((poh / 1000))k"
            else
                poh_fmt="${poh}"
            fi
        else
            poh_fmt="${poh}"
            poh_col=$C_GRAY
        fi

        local serial_fmt="${serial}"
        if [[ ${#serial_fmt} -gt 6 ]]; then
            serial_fmt="${serial_fmt: -6}"
        fi
        
        local type_col=$C_YELLOW
        if [[ "$type" == "SSD" ]]; then
            type_col=$C_CYAN
        fi
        
        local temp_col=$C_GREEN
        if [[ $temp -ge 50 ]]; then
            temp_col=$C_RED
        elif [[ $temp -ge 40 ]]; then
            temp_col=$C_YELLOW
        fi
        
        local err_col=$C_GREEN
        if [[ $uncorr -ne 0 || $pend -ne 0 ]]; then
            err_col=$C_RED
        fi
        
        local state_txt err_str state_col
        state_txt=$(echo "$state" | awk -F'|' '{print $2" "$3}' | trim || true)
        err_str="${uncorr}(${pend},${realloc})"
        
        state_col=$C_GRAY
        case "${state_txt}" in
            *faulty*|*fail*) state_col=$C_RED ;;
            *spare*)         state_col=$C_BLUE ;;
            *rebuild*|*recover*|*resync*) state_col=$C_YELLOW ;;
        esac

        local model_col=$C_WHITE
        if [[ "$poh_col" == "$C_RED" || "$temp_col" == "$C_RED" || "$err_col" == "$C_RED" || "$state_col" == "$C_RED" ]]; then
            model_col=$C_RED
        fi
        
        printf "  ${model_col}%-24s${RESET} ${C_CYAN}%-10s${RESET} ${C_GRAY}%-8s${RESET} ${C_WHITE}%-8s${RESET} ${type_col}%-6s${RESET} ${poh_col}%-6s${RESET} ${temp_col}%-9s${RESET} ${err_col}%-14s${RESET} ${state_col}%s${RESET}\n" \
            "$model" "$dev" "$serial_fmt" "$size" "$type" "$poh_fmt" "${temp}°

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
            if [[ -z "$info" ]]; then
                continue
            fi
            
            show_raid "$md" "$info"
            
            raid_devs=$(echo "$info" | tail -n "$(echo "$info" | grep "Raid Devices" | awk -F: '{print $2}' | trim || echo 0)" | grep '/dev/' | awk '{print $7}' || true)
            remove="${raid_devs//[0-9]/}"
            non_raid=$(filter_devs "$non_raid" "$remove")
            
            raid_devs=$(echo "$raid_devs" | grep -v '/dev/md' || true)
            pattern=$(echo "${raid_devs//[0-9]/}" | tr '\n' '|' | sed 's/.$//' || true)
            
            if [[ -n "$patterheckn" ]]; then
                show_disks "$pattern" "$parted_out" "$all_devs" "$info"
            fi
            
            echo ""
        done
    fi
    
    if [[ -n "$non_raid" ]]; then
        echo -e "${C_MAGENTA}Standalone Disks${RESET}"
        local pattern
        pattern=$(echo "${non_raid//[0-9]/}" | tr '\n' '|' | sed 's/.$//' || true)
        if [[ -n "$pattern" ]]; then
            show_disks "$pattern" "$parted_out" "$all_devs" "" "$C_MAGENTA"
        fi
        echo ""
    fi
    
    echo -e "${C_GRAY}Last updated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}\n"
}

main "$@"
