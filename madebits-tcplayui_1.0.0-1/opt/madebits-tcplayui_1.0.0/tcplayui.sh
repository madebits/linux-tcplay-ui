#!/bin/bash

#openMountedFolderCommand=xdg-open
openMountedFolderCommand=pcmanfm

title="TcPlay: "
gui="zenity"

showError()
{
	if [[ "$1" ]]; then
		zenity --error --text="Error: $1"
	fi
	exit 1
}

ensureZero()
{
	if [[ $1 != 0 ]]; then
		showError "$2"
	fi
}

ensureSet()
{
	if [[ ! "$1" ]]; then
		showError "$2"
	fi
}

runAsRoot()
{
	if [[ $(id -u) != "0" ]]; then
		containerFile="$2"
		if [[ ! -f "$2" ]]; then
			containerFile=$($gui --file-selection --filename="$HOME/dummypath" --title="${title}Select TrueCrypt container file" 2> /dev/null)
		fi	
		ensureZero $?
		gksu "$0" "$containerFile" "$USER" "$HOME"
		exit 0
	fi	
}

getKeyFiles()
{
	msg="\n\nIf [Yes], you will be offered to select key files one by one, press [Cancel] in the next file selection dialog when done."
	$gui --question --title="${title}Key Files" --text="Container: $(readlink -f "$containerFile")\n\nAre you using key files?\n\nSelect [No] if you are NOT using key files, or [Yes] if you are using them.${msg}"
	if [[ $? == 0 ]] ; then
		while [[ 1 ]] ; do
			keyFile=$($gui --file-selection --title="${title}Select Key File" 2> /dev/null)
			if [[ $? != 0 ]] ; then
				break;
			fi
			keyFiles+=("-k \"$keyFile\"")
		done
		$gui --question --title="${title}Hidden Volume Key Files" --text="To map outer volume and protect any hidden volume specify hidden key files.\n\nSelect [No] if you are NOT using hidden volume key files, or [Yes] if you are using them.${msg}"
		if [[ $? == 0 ]] ; then
			while [[ 1 ]] ; do
				keyFile=$($gui --file-selection --title="${title}Select Hidden Key File" 2> /dev/null)
				if [[ $? != 0 ]] ; then
					break;
				fi
				hiddenKeyFiles+=("-f \"$keyFile\"")
				protect="-e"
			done
		fi
	fi	
}


runAsRoot $0 $1

ensureSet "$1" "No container"
if [ ! -f "$1" ] ; then
	showError "No such file: $1"
fi
ensureSet "$2" "No user"
ensureSet "$3" "No home"


user="$2"
home="$3"
containerFile="$1"
uid=$(id -u "$user")
gid=$(id -g "$user")

echo "User: $user, UserId: $uid, GroupId: $gid, Home: $home"
echo "Container: $containerFile"

loopDevice=$(losetup -f);
ensureSet "$loopDevice" "No free loop device"
mapperId=$(date | md5sum | cut -d ' ' -f 1)
mountDir="$home/truecrypt/$(basename "$loopDevice")"

echo "Device: $loopDevice" 
echo "Mapper: $mapperId"
echo "MountDir: $mountDir"

mkdir -p "$mountDir" || showError "Cannot create folder: $mountDir"
losetup "$loopDevice" "$containerFile" || showError "Cannot create loop device: $loopDevice"

keyFiles=()
hiddenKeyFiles=()
protect=""
getKeyFiles

#echo ${keyFiles[*]}
#echo ${hiddenKeyFiles[*]}

for count in 1 2 3
do
	password=$(zenity --password --title="TrueCrypt Password")
	#password=$($gui --entry --title="${title}Password" --text="Enter TrueCrypt password (visible):")
	if [[ $? != 0 ]]; then
		losetup -d "$loopDevice"
		exit 1
	fi
	echo "$password" | tcplay -m "$mapperId" -d "$loopDevice" $protect ${keyFiles[*]} ${hiddenKeyFiles[*]}
	if [[ $? == 0 ]]; then
		ok="ok"
		break
	fi
done

password=""
keyFiles=()
hiddenKeyFiles=()

if [[ ! "$ok" ]]; then
	losetup -d "$loopDevice"
	showError "Wrong password"
fi

# vfat, ntfs
mount -o nosuid,uid="$uid",gid="$gid" "/dev/mapper/${mapperId}" "$mountDir"
if [[ $? != 0 ]]; then
	# whatever
	echo "failed"
	mount "/dev/mapper/${mapperId}" "$mountDir"
	if [[ $? != 0 ]]; then
		losetup -d "$loopDevice"
		dmsetup remove "$mapperId"
		rmdir "$mountDir"
		showError "Failed to mount: $mountDir"
	fi
	type bindfs
	if [[ $? == 0 ]]; then
		mountDirUser="${mountDir}${user}"
		mkdir -p "$mountDirUser"
		if [[ $? != 0 ]]; then
			losetup -d "$loopDevice"
			dmsetup remove "$mapperId"
			rmdir "$mountDir"
			showError "Failed to mount: $mountDirUser"
		fi
		bindfs -u $uid -g $gid "${mountDir}" "$mountDirUser"
		if [[ $? != 0 ]]; then
			rmdir "$mountDirUser"
			mountDirUser=""
		fi
	fi
fi

if [[ "$openMountedFolderCommand" ]]; then
	if [[ "$mountDirUser" ]]; then
		gksu -u "$user" "$openMountedFolderCommand" "$mountDirUser" &
	else	
		gksu -u "$user" "$openMountedFolderCommand" "$mountDir" &
	fi
fi

function cleanUp {
	if [[ "$mountDirUser" ]]; then
		fuser -km "$mountDirUser"
		sleep 2
		umount "$mountDirUser"
		rmdir "$mountDirUser"
	fi
	fuser -km "$mountDir"
	sleep 2
	umount "$mountDir"
	dmsetup remove "$mapperId"
	losetup -d "$loopDevice"
	rmdir "$mountDir"
}

trap cleanUp SIGHUP SIGINT SIGTERM

$gui --info --title="${title}Success!" --text="Mounted! Press [OK] to unmount!!!\n\nContainer: $containerFile\nMount folder: $mountDir\n$mountDirUser\n\nKeep this dialog open as long as you are using the mounted container!\n\nPress [OK] to unmount!!!"
cleanUp

echo "Done!"
