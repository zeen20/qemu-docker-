#!/usr/bin/env bash
set -Eeuo pipefail

# Docker environment variables

: "${DISK_IO:="native"}"          # I/O Mode, can be set to 'native', 'threads' or 'io_turing'
DISK_FMT="${DISK_FMT:="vhd"}"     # Disk file format, can be set to "raw" (default) or "qcow2" or "vhd"
: "${DISK_TYPE:=""}"              # Device type to be used, choose "ide", "usb", "blk" or "scsi"
: "${DISK_FLAGS:=""}"             # Specifies the options for use with the qcow2 disk format
: "${DISK_CACHE:="none"}"         # Caching mode, can be set to 'writeback' for better performance
: "${DISK_DISCARD:="on"}"         # Controls whether unmap (TRIM) commands are passed to the host.
: "${DISK_ROTATION:="1"}"         # Rotation rate, set to 1 for SSD storage and increase for HDD

fmt2ext() {
  local DISK_FMT=$1

  case "${DISK_FMT,,}" in
    qcow2)
      echo "qcow2"
      ;;
    raw)
      echo "img"
      ;;
    vhd)
      echo "vhd"
      ;;
    *)
      error "Unrecognized disk format: $DISK_FMT" && exit 78
      ;;
  esac
}

ext2fmt() {
  local DISK_EXT=$1

  case "${DISK_EXT,,}" in
    qcow2)
      echo "qcow2"
      ;;
    img)
      echo "raw"
      ;;
    vhd)
      echo "vhd"
      ;;
    *)
      error "Unrecognized file extension: .$DISK_EXT" && exit 78
      ;;
  esac
}

getSize() {
  local DISK_FILE=$1
  local DISK_EXT DISK_FMT

  DISK_EXT=$(echo "${DISK_FILE//*./}" | sed 's/^.*\.//')
  DISK_FMT=$(ext2fmt "$DISK_EXT")

  case "${DISK_FMT,,}" in
    raw)
      stat -c%s "$DISK_FILE"
      ;;
    qcow2)
      qemu-img info "$DISK_FILE" -f "$DISK_FMT" | grep '^virtual size: ' | sed 's/.*(\(.*\) bytes)/\1/'
      ;;
    vhd)
      # Add specific handling for VHD format
      vhd-tool info "$DISK_FILE" | grep 'Virtual size' | awk '{print $3}'
      ;;
    *)
      error "Unrecognized disk format: $DISK_FMT" && exit 78
      ;;
  esac
}

createDisk() {
  local DISK_FILE=$1
  local DISK_SPACE=$2
  local DISK_DESC=$3
  local DISK_FMT=$4
  local FS=$5
  local DATA_SIZE DIR SPACE FA

  DATA_SIZE=$(numfmt --from=iec "$DISK_SPACE")

  rm -f "$DISK_FILE"

  if [[ "$ALLOCATE" != [Nn]* ]]; then
    # Check free diskspace
    DIR=$(dirname "$DISK_FILE")
    SPACE=$(df --output=avail -B 1 "$DIR" | tail -n 1)

    if (( DATA_SIZE > SPACE )); then
      local SPACE_GB=$(( (SPACE + 1073741823)/1073741824 ))
      error "Not enough free space to create a $DISK_DESC of $DISK_SPACE in $DIR, it has only $SPACE_GB GB available..."
      error "Please specify a smaller ${DISK_DESC^^}_SIZE or disable preallocation by setting ALLOCATE=N." && exit 76
    fi
  fi

  html "Creating a $DISK_DESC image..."
  info "Creating a $DISK_SPACE $DISK_STYLE $DISK_DESC image in $DISK_FMT format..."

  local FAIL="Could not create a $DISK_STYLE $DISK_FMT $DISK_DESC image of $DISK_SPACE ($DISK_FILE)"

  case "${DISK_FMT,,}" in
    raw)
      if isCow "$FS"; then
        if ! touch "$DISK_FILE"; then
          error "$FAIL" && exit 77
        fi
        { chattr +C "$DISK_FILE"; } || :
      fi

      if [[ "$ALLOCATE" == [Nn]* ]]; then
        # Create an empty file
        if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
          rm -f "$DISK_FILE"
          error "$FAIL" && exit 77
        fi
      else
        # Create an empty file
        if ! fallocate -l "$DATA_SIZE" "$DISK_FILE"; then
          if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
            rm -f "$DISK_FILE"
            error "$FAIL" && exit 77
          fi
        fi
      fi
      ;;
    qcow2)
      local DISK_PARAM="$DISK_ALLOC"
      isCow "$FS" && DISK_PARAM="$DISK_PARAM,nocow=on"
      [ -n "$DISK_FLAGS" ] && DISK_PARAM="$DISK_PARAM,$DISK_FLAGS"

      if ! qemu-img create -f "$DISK_FMT" -o "$DISK_PARAM" -- "$DISK_FILE" "$DATA_SIZE" ; then
        rm -f "$DISK_FILE"
        error "$FAIL" && exit 70
      fi
      ;;
    vhd)
      # Use VHD specific tool to create the disk
      if ! vhd-tool create "$DISK_FILE" "$DATA_SIZE"; then
        rm -f "$DISK_FILE"
        error "$FAIL" && exit 70
      fi
      ;;
  esac

  if isCow "$FS"; then
    FA=$(lsattr "$DISK_FILE")
    if [[ "$FA" != *"C"* ]]; then
      error "Failed to disable COW for $DISK_DESC image $DISK_FILE on ${FS^^} filesystem (returned $FA)"
    fi
  fi

  return 0
}

resizeDisk() {
  local DISK_FILE=$1
  local DISK_SPACE=$2
  local DISK_DESC=$3
  local DISK_FMT=$4
  local FS=$5
  local CUR_SIZE DATA_SIZE DIR SPACE

  CUR_SIZE=$(getSize "$DISK_FILE")
  DATA_SIZE=$(numfmt --from=iec "$DISK_SPACE")
  local REQ=$((DATA_SIZE-CUR_SIZE))
  (( REQ < 1 )) && error "Shrinking disks is not supported yet, please increase ${DISK_DESC^^}_SIZE." && exit 71

  if [[ "$ALLOCATE" != [Nn]* ]]; then
    # Check free diskspace
    DIR=$(dirname "$DISK_FILE")
    SPACE=$(df --output=avail -B 1 "$DIR" | tail -n 1)

    if (( REQ > SPACE )); then
      local SPACE_GB=$(( (SPACE + 1073741823)/1073741824 ))
      error "Not enough free space to resize $DISK_DESC to $DISK_SPACE in $DIR, it has only $SPACE_GB GB available.."
      error "Please specify a smaller ${DISK_DESC^^}_SIZE or disable preallocation by setting ALLOCATE=N." && exit 74
    fi
  fi

  local GB=$(( (CUR_SIZE + 1073741823)/1073741824 ))
  MSG="Resizing $DISK_DESC from ${GB}G to $DISK_SPACE..."
  info "$MSG" && html "$MSG"

  local FAIL="Could not resize the $DISK_STYLE $DISK_FMT $DISK_DESC image from ${GB}G to $DISK_SPACE ($DISK_FILE)"

  case "${DISK_FMT,,}" in
    raw)
      if [[ "$ALLOCATE" == [Nn]* ]]; then
        # Resize file by changing its length
        if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
          error "$FAIL" && exit 75
        fi
      else
        # Resize file by allocating more space
        if ! fallocate -l "$DATA_SIZE" "$DISK_FILE"; then
          if ! truncate -s "$DATA_SIZE" "$DISK_FILE"; then
            error "$FAIL" && exit 75
          fi
        fi
      fi
      ;;
    qcow2)
      if ! qemu-img resize -f "$DISK_FMT" "--$DISK_ALLOC" "$DISK_FILE" "$DATA_SIZE" ; then
        error "$FAIL" && exit 72
      fi
      ;;
    vhd)
      # Use VHD specific resize functionality
      if ! vhd-tool resize "$DISK_FILE" "$DISK_SPACE"; then
        error "$FAIL" && exit 72
      fi
      ;;
  esac

  return 0
}

convertDisk() {
  local SOURCE_FILE=$1
  local SOURCE_FMT=$2
  local DST_FILE=$3
  local DST_FMT=$4
  local DISK_BASE=$5
  local DISK_DESC=$6
  local FS=$7

  [ -f "$DST_FILE" ] && error "Conversion failed, destination file $DST_FILE already exists?" && exit 79
  [ ! -f "$SOURCE_FILE" ] && error "Conversion failed, source file $SOURCE_FILE does not exists?" && exit 79

  local FAIL="Could not convert $SOURCE_FMT disk $SOURCE_FILE to $DST_FMT disk $DST_FILE."

  case "$DST_FMT" in
    qcow2)
      # Handle conversion from source to qcow2
      if ! qemu-img convert -f "$SOURCE_FMT" -O qcow2 "$SOURCE_FILE" "$DST_FILE"; then
        error "$FAIL" && exit 78
      fi
      ;;
    raw)
      # Handle conversion to raw format
      if ! qemu-img convert -f "$SOURCE_FMT" -O raw "$SOURCE_FILE" "$DST_FILE"; then
        error "$FAIL" && exit 78
      fi
      ;;
    vhd)
      # Handle conversion to VHD format
      if ! vhd-tool convert "$SOURCE_FILE" "$DST_FILE"; then
        error "$FAIL" && exit 78
      fi
      ;;
    *)
      error "Unsupported target format $DST_FMT for conversion." && exit 80
      ;;
  esac

  info "Successfully converted $SOURCE_FMT disk $SOURCE_FILE to $DST_FMT disk $DST_FILE."
  return 0
}
