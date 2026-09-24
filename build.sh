#!/bin/bash
export ARCH=arm64
export SUBARCH=arm64
export TARGET_PRODUCT=fuxi

# Auto-update ReSukiSU to latest
if [ -d KernelSU/.git ]; then
    echo "[+] Updating ReSukiSU..."
    cd KernelSU
    git stash --quiet 2>/dev/null
    git pull --ff-only 2>/dev/null && echo "[-] Updated to latest" || echo "[-] Pull failed, using current version"
    cd ..
fi

# Auto-update Re:Kernel from myflavor/Re-Kernel
if [ -d Re-Kernel/.git ]; then
    echo "[+] Updating Re:Kernel..."
    cd Re-Kernel
    git stash --quiet 2>/dev/null
    git pull --ff-only 2>/dev/null && echo "[-] Updated to latest" || echo "[-] Pull failed, using current version"
    cd ..
fi

# ---- 适配较新 binder: rkx 直接查内核真符号 binder_alloc_copy_from_buffer ----
RKX_DIR="drivers/rekernel"
if [ -f "$RKX_DIR/rkx_binder_kp.c" ]; then
    echo "[+] Patching rkx_binder_kp.c: 去掉版本分支, 只保留 kallsyms 查真符号"
    perl -0777 -i -pe 's/#if LINUX_VERSION_CODE < KERNEL_VERSION\(6, 0, 0\)\n\s*k_binder_alloc_copy_from_buffer = rk_binder_alloc_copy_from_buffer;\n#else\n(\s*k_binder_alloc_copy_from_buffer = \(void \*\)k_kallsyms_lookup_name\("binder_alloc_copy_from_buffer"\);\n)#endif\n/$1/s' "$RKX_DIR/rkx_binder_kp.c"
fi
if [ -f "$RKX_DIR/rkx_binder_alloc.c" ]; then
    echo "[+] Overwriting rkx_binder_alloc.c: 直接转调内核真符号 binder_alloc_copy_from_buffer"
    cat > "$RKX_DIR/rkx_binder_alloc.c" <<'RKXEOF'
/*
 * rkx_binder_alloc.c — 已覆写以适配较新 binder.
 * legacy 缓冲区拷贝实现(依赖旧 binder 内部结构)已移除;
 * rkx_binder_copy_from_buffer 直接转调内核真符号 binder_alloc_copy_from_buffer.
 */

#include "rkx_binder_alloc.h"

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 0, 0)

#include <linux/kprobes.h>

int rkx_binder_copy_from_buffer(struct binder_alloc *alloc, void *dest,
	struct binder_buffer *buffer, binder_size_t buffer_offset, size_t bytes)
{
	static int (*real_copy_from_buffer)(struct binder_alloc *, void *,
		struct binder_buffer *, binder_size_t, size_t);

	if (!real_copy_from_buffer) {
		unsigned long (*lookup)(const char *);
		struct kprobe kp = { .symbol_name = "kallsyms_lookup_name" };

		if (register_kprobe(&kp) < 0)
			return -EINVAL;
		lookup = (void *)kp.addr;
		unregister_kprobe(&kp);
		if (!lookup)
			return -EINVAL;
		real_copy_from_buffer = (void *)lookup("binder_alloc_copy_from_buffer");
	}
	if (!real_copy_from_buffer)
		return -EINVAL;

	return real_copy_from_buffer(alloc, dest, buffer, buffer_offset, bytes);
}
#endif
RKXEOF
fi

MAKE_PARAMS="LLVM=1 LLVM_IAS=1 O=out LOCALVERSION=-AOSPA-BY@Samrtin"

mkdir -p out
make $MAKE_PARAMS fuxi_defconfig -j$(nproc --all)
make $MAKE_PARAMS Image -j$(nproc --all) 2>&1 | tee out/build.log

if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "[!] Build failed. Check out/build.log for details."
    exit 1
fi

# Prepare AnyKernel3 flashable zip
rm -rf out/AK3
cp -r tools/AK3 out/

cp out/arch/arm64/boot/Image out/AK3/Image
cd out/AK3
ZIPNAME="Fuxi-ReSukiSU-$(date -u '+%Y%m%d-%H%M').zip"
zip -r9 "$ZIPNAME" .
find . -not -name "*.zip" -not -name "." -exec rm -rf {} + 2>/dev/null
echo "[-] Zip created in: out/AK3/"
cp "$ZIPNAME" ~/
echo "[-] Also copied to: ~/$ZIPNAME"
