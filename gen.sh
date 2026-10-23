#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

ROOT="AuroraProxy"
APP="$ROOT/app/src/main/java/com/example/auroraproxy"
RES="$ROOT/app/src/main/res"

mkdir -p "$APP" "$RES/values" "$RES/drawable" "$ROOT/app/libs"
cd "$ROOT"

cat > settings.gradle <<'EOF'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "AuroraProxy"
include ':app'
EOF

cat > build.gradle <<'EOF'
plugins {
    id 'com.android.application' version '8.7.3' apply false
}
EOF

cat > gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
android.nonTransitiveRClass=true
EOF

cat > app/build.gradle <<'EOF'
plugins {
    id 'com.android.application'
}

android {
    namespace 'com.example.auroraproxy'
    compileSdk 35

    defaultConfig {
        applicationId "com.example.auroraproxy"
        minSdk 29
        targetSdk 33
        versionCode 1
        versionName "1.0"
    }

    buildTypes {
        release {
            minifyEnabled false
        }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

def libboxAar = file('libs/libbox.aar')
dependencies {
    if (libboxAar.exists()) {
        implementation files('libs/libbox.aar')
    }
}
EOF

cat > app/proguard-rules.pro <<'EOF'
-keep class libbox.** { *; }
-keep class io.nekohasekai.libbox.** { *; }
-keep class go.** { *; }
EOF

cat > app/src/main/AndroidManifest.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <application
        android:allowBackup="false"
        android:extractNativeLibs="true"
        android:icon="@drawable/ic_launcher"
        android:label="Aurora Proxy"
        android:theme="@style/AppTheme">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".ProxyVpnService"
            android:exported="false"
            android:permission="android.permission.BIND_VPN_SERVICE">
            <intent-filter>
                <action android:name="android.net.VpnService" />
            </intent-filter>
        </service>
    </application>
</manifest>
EOF

# ---- end of part 1 ----
cat > app/src/main/res/values/styles.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="AppTheme" parent="@android:style/Theme.Material.Light.NoActionBar">
        <item name="android:fontFamily">sans</item>
        <item name="android:colorAccent">#2563EB</item>
        <item name="android:statusBarColor">#FFFFFF</item>
        <item name="android:navigationBarColor">#FFFFFF</item>
        <item name="android:windowLightStatusBar">true</item>
    </style>
</resources>
EOF

cat > app/src/main/res/values/strings.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">Aurora Proxy</string>
</resources>
EOF

cat > app/src/main/res/drawable/ic_launcher.xml <<'EOF'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:fillColor="#2563EB" android:pathData="M0,0h108v108h-108z"/>
    <path android:fillColor="#FFFFFF" android:pathData="M24,78 L54,24 L84,78 L68,78 L54,52 L40,78 Z"/>
</vector>
EOF

cat > app/src/main/res/drawable/ic_stat_proxy.xml <<'EOF'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path android:fillColor="#FFFFFFFF" android:pathData="M4,18 L12,4 L20,18 L15,18 L12,12 L9,18 Z"/>
</vector>
EOF

cat > "$APP/StatusBus.java" <<'JAVA_EOF'
package com.example.auroraproxy;

import android.os.Handler;
import android.os.Looper;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

public final class StatusBus {
    public interface Listener {
        void onStatus(String text, boolean running);
    }

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final List<Listener> LISTENERS = new CopyOnWriteArrayList<>();
    private static volatile String lastText = "未连接";
    private static volatile boolean lastRunning = false;

    private StatusBus() {
    }

    public static void register(Listener listener) {
        LISTENERS.add(listener);
        MAIN.post(() -> listener.onStatus(lastText, lastRunning));
    }

    public static void unregister(Listener listener) {
        LISTENERS.remove(listener);
    }

    public static void post(String text, boolean running) {
        lastText = text;
        lastRunning = running;
        MAIN.post(() -> {
            for (Listener listener : LISTENERS) {
                listener.onStatus(text, running);
            }
        });
    }
}
JAVA_EOF

# ---- end of part 2 ----
cat > "$APP/ConfigBuilder.java" <<'JAVA_EOF'
package com.example.auroraproxy;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 把用户粘贴的 sing-box 配置改写成 Android 可用的运行时配置：
 * 1. 只有单个节点也能用（自动补成完整 outbounds）
 * 2. inbound 统一换成 VpnService 建立的 tun
 * 3. route.final 兜底，清理指向不存在出站的规则
 */
public final class ConfigBuilder {
    public static final int MTU = 9000;
    public static final String TUN_ADDRESS = "172.19.0.1/30";
    public static final String TUN_TAG = "tun-in";
    public static final String DIRECT_TAG = "direct";

    private ConfigBuilder() {
    }

    public static String build(String input) throws Exception {
        return build(input, null);
    }

    public static String build(String input, String cachePath) throws Exception {
        if (input == null || input.trim().isEmpty()) {
            throw new Exception("配置为空，请先粘贴或导入 sing-box JSON");
        }

        JSONObject root;
        try {
            root = new JSONObject(input.trim());
        } catch (Exception e) {
            throw new Exception("不是合法 JSON：" + e.getMessage());
        }

        root = wrapSingleNode(root);

        JSONArray outbounds = root.optJSONArray("outbounds");
        if (outbounds == null || outbounds.length() == 0) {
            throw new Exception("outbounds 为空，至少需要一个出站节点");
        }

        String fallbackTag = normalizeOutbounds(root);
        installTun(root);
        installRoute(root, fallbackTag);
        installLog(root);
        installExperimental(root, cachePath);

        return root.toString(2);
    }

    /** 单个节点（含 type + server）自动包装成完整配置。 */
    private static JSONObject wrapSingleNode(JSONObject root) throws Exception {
        if (root.has("outbounds")) {
            return root;
        }
        if (!root.has("type") || !root.has("server")) {
            throw new Exception("需要完整 sing-box 配置（含 outbounds），或单个节点（含 type 和 server）");
        }

        JSONObject node = new JSONObject(root.toString());
        if (isBlank(node.optString("tag", ""))) {
            node.put("tag", "proxy");
        }
        String tag = node.getString("tag");

        JSONArray outbounds = new JSONArray();
        outbounds.put(node);
        outbounds.put(directOutbound());

        JSONObject route = new JSONObject();
        route.put("final", tag);

        JSONObject wrapper = new JSONObject();
        wrapper.put("outbounds", outbounds);
        wrapper.put("route", route);
        return wrapper;
    }

    /** 补全缺失的 tag，确保存在 direct，返回第一个 tag 作为兜底出站。 */
    private static String normalizeOutbounds(JSONObject root) throws Exception {
        JSONArray outbounds = root.getJSONArray("outbounds");
        String firstTag = null;
        boolean hasDirect = false;

        for (int i = 0; i < outbounds.length(); i++) {
            JSONObject outbound = outbounds.optJSONObject(i);
            if (outbound == null) {
                continue;
            }
            String tag = outbound.optString("tag", "");
            if (isBlank(tag)) {
                tag = "outbound-" + i;
                outbound.put("tag", tag);
            }
            if (firstTag == null) {
                firstTag = tag;
            }
            if ("direct".equals(outbound.optString("type"))) {
                hasDirect = true;
            }
        }

        if (firstTag == null) {
            throw new Exception("outbounds 里没有有效节点");
        }
        if (!hasDirect) {
            outbounds.put(directOutbound());
        }
        return firstTag;
    }

    /** 原配置里的 inbound 全部丢掉，换成 VpnService 的 tun。 */
    private static void installTun(JSONObject root) throws Exception {
        JSONObject tun = new JSONObject();
        tun.put("type", "tun");
        tun.put("tag", TUN_TAG);
        tun.put("address", new JSONArray().put(TUN_ADDRESS));
        tun.put("mtu", MTU);
        tun.put("auto_route", false);
        tun.put("strict_route", false);
        tun.put("stack", "gvisor");

        JSONArray inbounds = new JSONArray();
        inbounds.put(tun);
        root.put("inbounds", inbounds);
    }

    private static void installRoute(JSONObject root, String fallbackTag) throws Exception {
        JSONArray outbounds = root.getJSONArray("outbounds");

        JSONObject route = root.optJSONObject("route");
        if (route == null) {
            route = new JSONObject();
            root.put("route", route);
        }

        // 出站走 App 自己的底层网络，不依赖系统接口探测。
        route.put("auto_detect_interface", false);

        String finalTag = route.optString("final", "");
        if (isBlank(finalTag) || !tagExists(outbounds, finalTag)) {
            route.put("final", fallbackTag);
        }

        JSONArray cleaned = new JSONArray();
        JSONArray rules = route.optJSONArray("rules");
        if (rules != null) {
            for (int i = 0; i < rules.length(); i++) {
                JSONObject rule = rules.optJSONObject(i);
                if (rule == null) {
                    continue;
                }

cat > "$APP/ProxyVpnService.java" <<'JAVA_EOF'
package com.example.auroraproxy;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.VpnService;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * VPN 服务：负责建立 TUN、通过反射启动 libbox 内核、维护前台通知。
 *
 * libbox 通过 app/libs/libbox.aar 提供，但 AAR 由 CI 现编，
 * 所以这里用反射调用，避免和具体版本的方法签名绑死。
 * 若启动失败，logcat 过滤标签 AuroraProxy 可以看到完整原因。
 */
public class ProxyVpnService extends VpnService {
    public static final String ACTION_START = "com.example.auroraproxy.action.START";
    public static final String ACTION_STOP = "com.example.auroraproxy.action.STOP";
    public static final String EXTRA_CONFIG = "config";

    private static final String TAG = "AuroraProxy";
    private static final String CHANNEL_ID = "vpn";
    private static final int NOTIFICATION_ID = 1001;
    private static final long TUN_TIMEOUT_SECONDS = 20;

    private static volatile Class<?> libboxClass;

    private final Object stateLock = new Object();

    private volatile boolean running;
    private volatile Object boxService;
    private volatile Thread worker;
    private volatile CountDownLatch tunLatch = new CountDownLatch(1);
    private ParcelFileDescriptor tunFd;

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? null : intent.getAction();

        if (ACTION_STOP.equals(action)) {
            stopVpn();
            return START_NOT_STICKY;
        }

        if (ACTION_START.equals(action) || action == null) {
            String config = intent == null ? null : intent.getStringExtra(EXTRA_CONFIG);
            if (config == null || config.trim().isEmpty()) {
                SharedPreferences preferences = getSharedPreferences("config", MODE_PRIVATE);
                config = preferences.getString("config", null);
            }
            if (config == null || config.trim().isEmpty()) {
                StatusBus.post("没有可用配置", false);
                stopSelf();
                return START_NOT_STICKY;
            }
            startVpn(config);
            return START_STICKY;
        }

        return START_NOT_STICKY;
    }

    private void startVpn(String configJson) {
        synchronized (stateLock) {
            if (running) {
                StatusBus.post("已连接", true);
                return;
            }
            running = true;
            tunLatch = new CountDownLatch(1);
        }

        startForeground(NOTIFICATION_ID, buildNotification("正在连接…"));
        StatusBus.post("正在启动内核…", false);

        Thread thread = new Thread(() -> runCore(configJson), "aurora-vpn");
        worker = thread;
        thread.start();
    }

    private void runCore(String configJson) {
        try {
            String cachePath = new File(getFilesDir(), "cache.db").getAbsolutePath();
            String runtimeConfig = ConfigBuilder.build(configJson, cachePath);
            Log.d(TAG, "runtime config:\n" + runtimeConfig);

            // 先建立 TUN，libbox 通过 openTun 回调拿走同一个 fd。
            ensureTun();

            Object platform = createPlatformProxy();
            Object service = newService(runtimeConfig, platform);
            boxService = service;
            Log.d(TAG, "core created: " + service.getClass().getName());

            Thread starter = new Thread(() -> runCoreBlocking(service), "aurora-core");
            starter.start();

            if (!tunLatch.await(TUN_TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                throw new IllegalStateException(
                        "等待内核建立 TUN 超时（" + TUN_TIMEOUT_SECONDS + " 秒），logcat 过滤 AuroraProxy 查看原因");
            }

            updateNotification("已连接");
            StatusBus.post("已连接（TUN 全局模式）", true);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (Throwable e) {
            Log.e(TAG, "startVpn failed", e);
            StatusBus.post("启动失败：" + rootMessage(e), false);
            stopVpn();
        }
    }

    private void runCoreBlocking(Object service) {
        try {
            Method start = service.getClass().getMethod("start");
            start.invoke(service);
            StatusBus.post("内核已停止", false);
        } catch (Throwable e) {
            Log.e(TAG, "core start failed", e);
            StatusBus.post("内核停止：" + rootMessage(e), false);
        }
        stopVpn();
    }

    // ---------------- libbox 平台接口（动态代理） ------
# 修正前几段中 $APP 相对路径造成的嵌套目录
if [ -d "AuroraProxy/app/src/main/java/com/example/auroraproxy" ]; then
  mkdir -p app/src/main/java/com/example/auroraproxy
  mv AuroraProxy/app/src/main/java/com/example/auroraproxy/*.java app/src/main/java/com/example/auroraproxy/ 2>/dev/null || true
  rm -rf AuroraProxy
fi
APP="app/src/main/java/com/example/auroraproxy"

cat > "$APP/MainActivity.java" <<'JAVA_EOF'
package com.example.auroraproxy;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.text.InputType;
import android.util.Base64;
import android.util.TypedValue;
import android.view.Gravity;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity implements StatusBus.Listener {
    private static final int REQ_VPN = 1001;
    private static final int REQ_FILE = 1002;
    private static final int REQ_NOTIFICATION = 1003;
    private static final String PREFS = "config";
    private static final String KEY_CONFIG = "config";

    private EditText configEdit;
    private TextView statusView;
    private TextView logView;
    private Button connectButton;
    private Button disconnectButton;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        loadConfig();
        requestNotificationPermission();
    }

    private void buildUi() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int padding = dp(16);
        root.setPadding(padding, padding, padding, padding);

        TextView title = new TextView(this);
        title.setText("Aurora Proxy");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        root.addView(title);

        TextView hint = new TextView(this);
        hint.setText("Android MVP · sing-box 内核 · TUN 全局模式\n"
                + "支持 sing-box JSON / base64(JSON)。Clash、v2ray 订阅需先转成 sing-box JSON。");
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        hint.setPadding(0, dp(4), 0, dp(12));
        root.addView(hint);

        statusView = new TextView(this);
        statusView.setText("未连接");
        statusView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        statusView.setPadding(0, 0, 0, dp(12));
        root.addView(statusView);

        configEdit = new EditText(this);
        configEdit.setGravity(Gravity.TOP | Gravity.START);
        configEdit.setInputType(InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        configEdit.setTypeface(android.graphics.Typeface.MONOSPACE);
        configEdit.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        configEdit.setMinLines(10);
        configEdit.setMaxLines(18);
        configEdit.setHorizontallyScrolling(false);
        configEdit.setHint("{\n  \"outbounds\": [ ... ]\n}");
        root.addView(configEdit, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        LinearLayout row1 = new LinearLayout(this);
        row1.setOrientation(LinearLayout.HORIZONTAL);
        row1.setPadding(0, dp(8), 0, 0);
        Button importFile = makeButton("导入文件");
        Button importUrl = makeButton("导入订阅");
        Button save = makeButton("保存");
        row1.addView(importFile, weightParams());
        row1.addView(importUrl, weightParams());
        row1.addView(save, weightParams());
        root.addView(row1);

        LinearLayout row2 = new LinearLayout(this);
        row2.setOrientation(LinearLayout.HORIZONTAL);
        row2.setPadding(0, dp(8), 0, 0);
        connectButton = makeButton("连接");
        disconnectButton = makeButton("断开");
        row2.addView(connectButton, weightParams());
        row2.addView(disconnectButton, weightParams());
        root.addView(row2);

        logView = new TextView(this);
        logView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        logView.setTypeface(android.graphics.Typeface.MONOSPACE);
        logView.setPadding(0, dp(12), 0, 0);
        logView.setText("日志：");
        root.addView(logView);

        ScrollView scrollView = new ScrollView(this);
        scrollView.addView(root);
        setContentView(scrollView);

        importFile.setOnClickListener(v -> pickFile());
        importUrl.setOnClickListener(v -> showImportDialog());
        save.setOnClickListener(v -> {
            saveConfig();
            toast("已保存");
        });
        connectButton.setOnClickListener(v -> connect());
        disconnectButton.setOnClickListener(v -> disconnect());
        updateButtons(false);
    }

    private Button makeButton(String text) {
        Button button = new Button(this);
        button.setText(text);
        button.setAllCaps(false);
        return button;
    }

    private LinearLayout.LayoutParams weightParams() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f);
        params.setMargins(dp(4), 0, dp(4), 0);
        return params;
    }

    private int dp(int value) {
        return Math.round(getResources().getDisplayMetrics().density * value);
    }

    private void loadConfig() {
        SharedPreferences preferences = getSharedPreferences(PREFS, MODE_PRIVATE);
        String saved = preferences.getString(KEY_CONFIG, null);
        if (saved == null || saved.trim().isEmpty()) {
            saved = "{\n"
                    + "  \"log\": { \"level\": \"info\", \"timestamp\": true },\n"
                    + "  \"outbounds\": [\n"
                    + "    { \"type\": \"direct\", \"tag\": \"direct\" }\n"
                    + "  ]\n"
                    + "}\n";
        }
        configEdit.setText(saved);
    }

    private void saveConfig() {
        getSharedPreferences(PREFS, MODE_PRIVATE)
                .edit()
                .putString(KEY_CONFIG, configEdit.getText().toString())
                .apply();
    }

    private void connect() {
        saveConfig();
        String config = configEdit.getText().toString();
        try {
            String cachePath = new java.io.File(getFilesDir(), "cache.db").getAbsolutePath();
            ConfigBuilder.build(config, cachePath);
        } catch (Exception e) {
            toast("配置有问题：" + e.getMessage());
            return;
        }

        Intent prepare = VpnService.prepare(this);
        if (prepare != null) {
            startActivityForResult(prepare, REQ_VPN);
        } else {
            startProxyService();
        }
    }

    private void startProxyService() {
        Intent intent = new Intent(this, ProxyVpnService.class);
        intent.setAction(ProxyVpnService.ACTION_START);
        intent.putExtra(ProxyVpnService.EXTRA_CONFIG, configEdit.getText().toString());
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
        appendLog("已请求启动代理服务");
    }

    private void disconnect() {
        Intent intent = new Intent(this, ProxyVpnService.class);
        intent.setAction(ProxyVpnService.ACTION_STOP);
        startService(intent);
        appendLog("已请求断开");
    }

    private void pickFile() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_MIME_TYPES,
                new String[]{"application/json", "text/plain"});
        startActivityForResult(intent, REQ_FILE);
    }

    private void showImportDialog() {
        EditText input = new EditText(this);
        input.setHint("https://example.com/subscription");
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);

        int padding = dp(16);
        LinearLayout box = new LinearLayout(this);
        box.setPadding(padding, padding, padding, 0);
        box.addView(input, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        new AlertDialog.Builder(this)
                .setTitle("导入订阅")
                .setView(box)
                .setNegativeButton("取消", null)
                .setPositiveButton("导入", (dialog, which) ->
                        fetchSubscription(input.getText().toString().trim()))
                .show();
    }

    private void fetchSubscription(String urlText) {
        if (urlText.isEmpty()) {
            return;
        }
        appendLog("正在下载订阅…");
        new Thread(() -> {
            try {
                URL url = new URL(urlText);
                HttpURLConnection connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(15000);
                connection.setReadTimeout(20000);
                connection.setRequestProperty("User-Agent", "AuroraProxy/1.0");
                connection.setInstanceFollowRedirects(true);

                int code = connection.getResponseCode();
                if (code < 200 || code >= 300) {
                    throw new Exception("HTTP " + code);
                }

                InputStream input = connection.getInputStream();
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                int read;
                while ((read = input.read(buffer)) != -1) {
                    output.write(buffer, 0, read);
                }
                input.close();

                String text = new String(output.toByteArray(), StandardCharsets.UTF_8).trim();
                String json = normalizeSubscription(text);

                runOnUiThread(() -> {
                    configEdit.setText(json);
                    saveConfig();
                    appendLog("订阅导入成功");
                    toast("订阅已导入");
                });
            } catch (Exception e) {
                runOnUiThread(() -> {
                    appendLog("订阅导入失败：" + e.getMessage());
                    toast("导入失败");
                });
            }
        }, "subscription-fetch").start();
    }

    private String normalizeSubscription(String text) throws Exception {
        if (text.startsWith("{")) {
            return text;
        }
        String decoded = decodeBase64Json(text);
        if (decoded != null) {
            return decoded;
        }
        throw new Exception("订阅既不是 sing-box JSON，也不是 base64(JSON)");
    }

    private String decodeBase64Json(String text) {
        String compact = text.replaceAll("\\s+", "");
        try {
            byte[] decoded = Base64.decode(compact, Base64.DEFAULT);
            String result = new String(decoded, StandardCharsets.UTF_8).trim();
            if (result.startsWith("{")) {
                return result;
            }
        } catch (Exception ignored) {
        }
        try {
            byte[] decoded = Base64.decode(
                    compact,
                    Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
            String result = new String(decoded, StandardCharsets.UTF_8).trim();
            if (result.startsWith("{")) {
                return result;
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);

        if (requestCode == REQ_VPN) {
            if (resultCode == RESULT_OK) {
                startProxyService();
            } else {
                toast("未授予 VPN 权限");
            }
            return;
        }

        if (requestCode == REQ_FILE && resultCode == RESULT_OK && data != null) {
            Uri uri = data.getData();
            if (uri == null) {
                return;
            }
            try (InputStream input = getContentResolver().openInputStream(uri)) {
                ByteArrayOutputStream output = new ByteArrayOutputStream();
                byte[] buffer = new byte[8192];
                int read;
                while (input != null && (read = input.read(buffer)) != -1) {
                    output.write(buffer, 0, read);
                }
                String text = new String(output.toByteArray(), StandardCharsets.UTF_8);
                String json = normalizeSubscription(text);
                configEdit.setText(json);
                saveConfig();
                appendLog("文件导入成功");
            } catch (Exception e) {
                toast("文件读取失败：" + e.getMessage());
            }
        }
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission("android.permission.POST_NOTIFICATIONS")
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(
                    new String[]{"android.permission.POST_NOTIFICATIONS"},
                    REQ_NOTIFICATION);
        }
    }

    @Override
    protected void onStart() {
        super.onStart();
        StatusBus.register(this);
    }

    @Override
    protected void onStop() {
        StatusBus.unregister(this);
        super.onStop();
    }

    @Override
    public void onStatus(String text, boolean running) {
        statusView.setText(text);
        updateButtons(running);
        appendLog(text);
    }

    private void updateButtons(boolean running) {
        if (connectButton != null) {
            connectButton.setEnabled(!running);
        }
        if (disconnectButton != null) {
            disconnectButton.setEnabled(running);
        }
    }

    private void appendLog(String line) {
        if (logView == null) {
            return;
        }
        String old = logView.getText().toString();
        if (old.length() > 6000) {
            old = old.substring(old.length() - 4000);
        }
        logView.setText(old + "\n" + line);
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }
}
JAVA_EOF

# ---- end of part 5 ----
echo "AuroraProxy generated."
