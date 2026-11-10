package com.pantry.server;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;

/**
 * 库房手机断电重启后把服务拉起来。
 *
 * Android 12 起禁止从后台启动前台服务，但 BOOT_COMPLETED 是明确豁免的广播之一。
 * 权限没给或已经跑着就直接返回，避免重复起服务、也避免弹一堆失败通知。
 */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        if (i == null || !Intent.ACTION_BOOT_COMPLETED.equals(i.getAction())) return;
        if (ServerService.RUNNING) return;
        if (!Env.allFilesAccess(c)) return;
        Intent s = new Intent(c, ServerService.class);
        try {
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(s);
            else c.startService(s);
        } catch (Exception e) {
            Env.log(c, "开机自启失败：" + e);
        }
    }
}
