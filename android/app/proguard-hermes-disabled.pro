# A normal release must not retain the sender or its external destination.
# Local preview, if separately enabled, may still use the report contract.
-assumenosideeffects class com.tecclub.flutter_singbox.diagnostics.HermesPilotGate {
    public boolean enabled(android.content.Context) return false;
}
