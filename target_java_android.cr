require "./target_java"

class JavaAndroidTarget < JavaTarget
  def gen
    @io << <<-END

import android.annotation.SuppressLint;
import android.app.Application;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Point;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Parcel;
import android.os.Parcelable;
import android.provider.Settings;
import android.util.Base64;
import android.util.Log;
import android.view.Display;
import android.view.WindowManager;

import com.facebook.stetho.Stetho;
import com.facebook.stetho.okhttp3.StethoInterceptor;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigInteger;
import java.net.InetAddress;
import java.net.Socket;
import java.net.UnknownHostException;
import java.security.KeyManagementException;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.text.ParseException;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Calendar;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.TimeUnit;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;

import okhttp3.Call;
import okhttp3.ConnectionPool;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

public class API {
    static public boolean useStaging = false;

END

    @ast.struct_types.each do |t|
      @io << ident generate_struct_type(t)
      @io << "\n\n"
    end

    @ast.enum_types.each do |t|
      @io << ident generate_enum_type(t)
      @io << "\n\n"
    end

    @ast.operations.each do |op|
      args = op.args.map {|arg| "final #{native_type arg.type} #{arg.name}" }
      args << "final #{callback_type op.return_type} callback"
      @io << ident(String.build do |io|
        io << "static public void #{op.pretty_name}(#{args.join(", ")}) {\n"
        io << ident(String.build do |io|
          if op.args.size == 0
            io << "JSONObject args = new JSONObject();"
          else
            io << <<-END
JSONObject args;
try {
    args = new JSONObject() {{

END
      op.args.each do |arg|
        io << ident ident "put(\"#{arg.name}\", #{type_to_json arg.type, arg.name});\n"
      end
          io << <<-END
    }};
} catch (JSONException e) {
    e.printStackTrace();
    callback.onResult(ErrorType.Fatal, e.getMessage()#{op.return_type.is_a?(AST::VoidPrimitiveType) ? "" : ", null"});
    return;
}
END
          end
          io << <<-END

Internal.makeRequest(#{op.pretty_name.inspect}, args, new Internal.RequestCallback() {
    @Override
    public void onResult(final ErrorType type, final String message, final JSONObject result) {

END
          if op.return_type.is_a? AST::VoidPrimitiveType
            io << <<-END
        if (type != null) {
            callback.onResult(type, message);
        } else {
            callback.onResult(null, null);
        }

END
          else
            io << <<-END
        if (type != null) {
            callback.onResult(type, message, null);
        } else {
            try {
                callback.onResult(null, null, #{type_from_json op.return_type, "result", "result".inspect});
            } catch (JSONException e) {
                e.printStackTrace();
                callback.onResult(ErrorType.Fatal, e.getMessage(), null);
            }
        }
END
          end
          io << <<-END
    }
});
END
        end)
        io << "}"
      end)
      @io << "\n\n"
    end

    @io << <<-END

    public interface Callback<T> {
        void onResult(ErrorType error, String message, T result);
    }

    public interface IntCallback {
        void onResult(ErrorType error, String message, int result);
    }

    public interface DoubleCallback {
        void onResult(ErrorType error, String message, double result);
    }

    public interface BooleanCallback {
        void onResult(ErrorType error, String message, boolean result);
    }

    public interface VoidCallback {
        void onResult(ErrorType error, String message);
    }

    static public void getDeviceId(final Callback<String> callback) {
        SharedPreferences pref = Internal.context().getSharedPreferences("api", Context.MODE_PRIVATE);
        if (pref.contains("deviceId"))
            callback.onResult(null, null, pref.getString("deviceId", null));
        else {
            ping(new Callback<String>() {
                @Override
                public void onResult(ErrorType error, String message, String result) {
                    if (error != null)
                        callback.onResult(error, message, null);
                    else
                        getDeviceId(callback);
                }
            });
        }
    }

    private static class Internal {
        static String baseUrl = "api.zigcore.com.br/pdv";
        static OkHttpClient http = null;
        static ConnectionPool connectionPool = new ConnectionPool();
        static SecureRandom random = new SecureRandom();
        static boolean initialized = false;
        static SimpleDateFormat dateTimeFormat = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US);
        static SimpleDateFormat dateFormat = new SimpleDateFormat("yyyy-MM-dd", Locale.US);

        static {
            dateTimeFormat.setTimeZone(TimeZone.getTimeZone("GMT"));
            dateFormat.setTimeZone(TimeZone.getTimeZone("GMT"));

            TrustManagerFactory trustManagerFactory;
            try {
                trustManagerFactory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
                trustManagerFactory.init((KeyStore) null);
            } catch (NoSuchAlgorithmException | KeyStoreException e) {
                e.printStackTrace();
                throw new RuntimeException(e);
            }
            TrustManager[] trustManagers = trustManagerFactory.getTrustManagers();
            if (trustManagers.length != 1 || !(trustManagers[0] instanceof X509TrustManager)) {
                throw new IllegalStateException("Unexpected default trust managers:"
                        + Arrays.toString(trustManagers));
            }
            X509TrustManager trustManager = (X509TrustManager) trustManagers[0];

            SSLSocketFactory sslSocketFactory;
            try {
                sslSocketFactory = new TLSSocketFactory();
            } catch (KeyManagementException | NoSuchAlgorithmException e) {
                e.printStackTrace();
                throw new RuntimeException(e);
            }

            http = new OkHttpClient.Builder()
                    .connectionPool(connectionPool)
                    .sslSocketFactory(sslSocketFactory, trustManager)
                    .addNetworkInterceptor(new StethoInterceptor())
                    .build();
        }

        static void initialize() {
            initialized = true;
            Stetho.initializeWithDefaults(context());
        }

        static Context context() {
            try {
                final Class<?> activityThreadClass =
                        Class.forName("android.app.ActivityThread");
                final Method method = activityThreadClass.getMethod("currentApplication");
                Application app = (Application)method.invoke(null, (Object[]) null);
                if (app == null)
                    throw new RuntimeException("");
                return app;
            } catch (final ClassNotFoundException | NoSuchMethodException |
                    IllegalArgumentException | InvocationTargetException | IllegalAccessException e) {
                throw new RuntimeException("");
            }
        }

        static String language() {
            Locale loc = Locale.getDefault();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                return loc.toLanguageTag();
            }

            final char SEP = '-';
            String language = loc.getLanguage();
            String region = loc.getCountry();
            String variant = loc.getVariant();

            if (language.equals("no") && region.equals("NO") && variant.equals("NY")) {
                language = "nn";
                region = "NO";
                variant = "";
            }

            if (language.isEmpty() || !language.matches("\\\\p{Alpha}{2,8}")) {
                language = "und";
            } else if (language.equals("iw")) {
                language = "he";
            } else if (language.equals("in")) {
                language = "id";
            } else if (language.equals("ji")) {
                language = "yi";
            }

            if (!region.matches("\\\\p{Alpha}{2}|\\\\p{Digit}{3}")) {
                region = "";
            }

            if (!variant.matches("\\\\p{Alnum}{5,8}|\\\\p{Digit}\\\\p{Alnum}{3}")) {
                variant = "";
            }

            StringBuilder bcp47Tag = new StringBuilder(language);
            if (!region.isEmpty()) {
                bcp47Tag.append(SEP).append(region);
            }
            if (!variant.isEmpty()) {
                bcp47Tag.append(SEP).append(variant);
            }

            return bcp47Tag.toString();
        }

        @SuppressLint("HardwareIds")
        static JSONObject device() throws JSONException {
            JSONObject device = new JSONObject();
            device.put("type", "android");
            device.put("fingerprint", "" + Settings.Secure.getString(context().getContentResolver(), Settings.Secure.ANDROID_ID));
            device.put("platform", new JSONObject() {{
                put("version", Build.VERSION.RELEASE);
                put("sdkVersion", Build.VERSION.SDK_INT);
                put("brand", Build.BRAND);
                put("model", Build.MODEL);
            }});
            try {
                device.put("version", context().getPackageManager().getPackageInfo(context().getPackageName(), 0).versionName);
            } catch (PackageManager.NameNotFoundException e) {
                device.put("version", "unknown");
            }
            device.put("language", language());
            device.put("screen", new JSONObject() {{
                WindowManager manager = (WindowManager) context().getSystemService(Context.WINDOW_SERVICE);
                Display display = manager.getDefaultDisplay();
                Point size = new Point();
                display.getSize(size);
                put("width", size.x);
                put("height", size.y);
            }});
            SharedPreferences pref = context().getSharedPreferences("api", Context.MODE_PRIVATE);
            if (pref.contains("deviceId"))
                device.put("id", pref.getString("deviceId", null));
            return device;
        }

        static String randomBytesHex(int len) {
            String str = new BigInteger(8 * len, random).toString(16);
            while (str.length() < 2*len) str = "0" + str;
            return str;
        }

        interface RequestCallback {
            void onResult(ErrorType type, String message, JSONObject result);
        }

        static void makeRequest(String name, JSONObject args, final RequestCallback callback) {
            if (!initialized) initialize();

            JSONObject body = new JSONObject();
            try {
                body.put("id", randomBytesHex(8));
                body.put("device", device());
                body.put("name", name);
                body.put("args", args);
            } catch (JSONException e) {
                e.printStackTrace();
                callback.onResult(ErrorType.Fatal, e.getMessage(), null);
            }

            final Request request = new Request.Builder()
                    .url("https://" + baseUrl + (API.useStaging ? "-staging" : "") + "/" + name)
                    .post(RequestBody.create(MediaType.parse("application/json; charset=utf-8"), body.toString()))
                    .build();

            final boolean shouldReceiveResponse[] = new boolean[] {true};
            final int sentCount[] = new int[] {0};
            final Timer timer = new Timer();
            final TimerTask task = new TimerTask() {
                @Override
                public void run() {
                    sentCount[0] += 1;
                    if (sentCount[0] % 5 == 0) {
                        connectionPool.evictAll();
                    }
                    http.newCall(request).enqueue(new okhttp3.Callback() {
                        @Override
                        public void onFailure(Call call, final IOException e) {
                            if (!shouldReceiveResponse[0]) return;
                            shouldReceiveResponse[0] = false;
                            timer.cancel();
                            new Handler(Looper.getMainLooper()).post(new Runnable() {
                                @Override
                                public void run() {
                                    e.printStackTrace();
                                    callback.onResult(ErrorType.Fatal, e.getMessage(), null);
                                }
                            });
                        }

                        @Override
                        public void onResponse(Call call, final Response response) throws IOException {
                            if (!shouldReceiveResponse[0]) return;
                            shouldReceiveResponse[0] = false;
                            timer.cancel();
                            final String stringBody = response.body().string();
                            new Handler(Looper.getMainLooper()).post(new Runnable() {
                                @Override
                                public void run() {
                                    if (response.code() >= 500) {
                                        Log.e("API Fatal", stringBody);
                                        callback.onResult(ErrorType.Fatal, "HTTP " + response.code(), null);
                                        return;
                                    }

                                    try {
                                        JSONObject body = new JSONObject(stringBody);

                                        SharedPreferences pref = context().getSharedPreferences("api", Context.MODE_PRIVATE);
                                        pref.edit().putString("deviceId", body.getString("deviceId")).apply();

                                        if (!body.getBoolean("ok")) {
                                            JSONObject error = body.getJSONObject("error");
                                            String message = error.getString("message");
                                            callback.onResult(error.getString("type").equals("NotLoggedIn") ? ErrorType.NotLoggedIn : error.getString("type").equals("LacksPermission") ? ErrorType.LacksPermission : error.getString("type").equals("InvalidArgument") ? ErrorType.InvalidArgument : error.getString("type").equals("WrongLogin") ? ErrorType.WrongLogin : error.getString("type").equals("DoesntExist") ? ErrorType.DoesntExist : error.getString("type").equals("Fatal") ? ErrorType.Fatal : error.getString("type").equals("Connection") ? ErrorType.Connection : null, message, null);
                                        } else {
                                            callback.onResult(null, null, body);
                                        }
                                    } catch (JSONException e) {
                                        e.printStackTrace();
                                        callback.onResult(ErrorType.Fatal, e.getMessage(), null);
                                    }
                                }
                            });
                        }
                    });
                }
            };

            timer.schedule(task, 0, 1000);
        }

        static Calendar toCalendar(Date date){
            Calendar cal = Calendar.getInstance();
            cal.setTime(date);
            return cal;
        }

        static Calendar decodeDateTime(String str) {
            try {
                return toCalendar(dateTimeFormat.parse(str));
            } catch (ParseException e) {
                e.printStackTrace();
                return null;
            }
        }

        static Calendar decodeDate(String str) {
            try {
                return toCalendar(dateFormat.parse(str));
            } catch (ParseException e) {
                e.printStackTrace();
                return null;
            }
        }

        static String encodeDateTime(Calendar cal) {
            return dateTimeFormat.format(cal.getTime());
        }

        static String encodeDate(Calendar cal) {
            return dateFormat.format(cal.getTime());
        }

        static private class TLSSocketFactory extends SSLSocketFactory {
            private SSLSocketFactory internalSSLSocketFactory;

            TLSSocketFactory() throws KeyManagementException, NoSuchAlgorithmException {
                SSLContext context = SSLContext.getInstance("TLS");
                context.init(null, null, null);
                internalSSLSocketFactory = context.getSocketFactory();
            }

            @Override
            public String[] getDefaultCipherSuites() {
                return internalSSLSocketFactory.getDefaultCipherSuites();
            }

            @Override
            public String[] getSupportedCipherSuites() {
                return internalSSLSocketFactory.getSupportedCipherSuites();
            }

            @Override
            public Socket createSocket() throws IOException {
                return enableTLSOnSocket(internalSSLSocketFactory.createSocket());
            }

            @Override
            public Socket createSocket(Socket s, String host, int port, boolean autoClose) throws IOException {
                return enableTLSOnSocket(internalSSLSocketFactory.createSocket(s, host, port, autoClose));
            }

            @Override
            public Socket createSocket(String host, int port) throws IOException, UnknownHostException {
                return enableTLSOnSocket(internalSSLSocketFactory.createSocket(host, port));
            }

            @Override
            public Socket createSocket(String host, int port, InetAddress localHost, int localPort) throws IOException, UnknownHostException {
                return enableTLSOnSocket(internalSSLSocketFactory.createSocket(host, port, localHost, localPort));
            }

            @Override
            public Socket createSocket(InetAddress host, int port) throws IOException {
                return enableTLSOnSocket(internalSSLSocketFactory.createSocket(host, port));
            }

            @Override
            public Socket createSocket(InetAddress address, int port, InetAddress localAddress, int localPort) throws IOException {
                return enableTLSOnSocket(internalSSLSocketFactory.createSocket(address, port, localAddress, localPort));
            }

            private Socket enableTLSOnSocket(Socket socket) {
                if (socket != null && (socket instanceof SSLSocket)) {
                    ((SSLSocket)socket).setEnabledProtocols(new String[] {"TLSv1.2"});
                }
                return socket;
            }
        }
    }
}
END
  end

  def callback_type(t : AST::Type)
    case t
    when AST::IntPrimitiveType;   "IntCallback"
    when AST::UIntPrimitiveType;  "IntCallback"
    when AST::FloatPrimitiveType; "DoubleCallback"
    when AST::BoolPrimitiveType;  "BooleanCallback"
    when AST::VoidPrimitiveType;  "VoidCallback"
    else
      "Callback<#{native_type_not_primitive(t)}>"
    end
  end
end

Target.register(JavaAndroidTarget, target_name: "java_android")
