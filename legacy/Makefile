build: clean-work
	./src/build.sh

clean-work:
	rm -rf ./work

clean-cache:
	rm -rf ./cache

clean: clean-work clean-cache

size-rootfs:
	du --max-depth=0 -h work/rootfs

chroot:
	sudo chroot work/rootfs

backup-rootfs:
	mkdir -p ./backup
	rm -f ./backup/rootfs.tar.gz
	cd ./work && tar -cpzf ../backup/rootfs.tar.gz ./rootfs