package com.aclaniakea.penwake.tools;

import android.database.sqlite.SQLiteDatabase;

import java.io.File;

/**
 * Enables / disables the PenStylusHook LSPosed module by editing LSPosed's own database
 * inside a transaction, so the change is visible before zygote starts.
 *
 *   LsposedSync enable  <db> <apk> <module>
 *   LsposedSync disable <db> <module>
 *
 * The framework scope is stored by LSPosed as "system" (the packaged scope.list calls it
 * "android").
 */
public final class LsposedSync {
    private static final String FRAMEWORK_SCOPE_IN_DB = "system";

    private LsposedSync() { }

    public static void main(String[] args) {
        if (args.length < 3) {
            throw new IllegalArgumentException(
                    "usage: LsposedSync enable <db> <apk> <module> | disable <db> <module>");
        }
        String mode = args[0];
        String database = args[1];
        if (!database.startsWith("/data/adb/lspd/")) {
            throw new IllegalArgumentException("refusing unexpected database path");
        }

        SQLiteDatabase.OpenParams params = new SQLiteDatabase.OpenParams.Builder()
                .setOpenFlags(SQLiteDatabase.OPEN_READWRITE
                        | SQLiteDatabase.NO_LOCALIZED_COLLATORS)
                .setJournalMode("WAL")
                .setSynchronousMode("NORMAL")
                .build();

        SQLiteDatabase db = SQLiteDatabase.openDatabase(new File(database), params);
        db.beginTransaction();
        try {
            if ("enable".equals(mode)) {
                if (args.length < 4) {
                    throw new IllegalArgumentException("enable needs <apk> <module>");
                }
                String apk = args[2];
                String module = args[3];
                if (!apk.startsWith("/data/adb/modules/")) {
                    throw new IllegalArgumentException("refusing unexpected apk path");
                }
                // UPDATE first, never REPLACE: SQLite implements REPLACE as
                // DELETE + INSERT and that can cascade into LSPosed's scope rows.
                db.execSQL("UPDATE modules SET apk_path=? WHERE module_pkg_name=?",
                        new Object[]{apk, module});
                db.execSQL("INSERT OR IGNORE INTO modules(module_pkg_name,apk_path) VALUES(?,?)",
                        new Object[]{module, apk});
                db.execSQL("UPDATE modules_state SET enabled=1 WHERE module_pkg_name=? AND user_id=0",
                        new Object[]{module});
                db.execSQL("INSERT OR IGNORE INTO modules_state"
                                + "(module_pkg_name,user_id,enabled,scope_request_blocked)"
                                + " VALUES(?,0,1,0)",
                        new Object[]{module});
                db.execSQL("INSERT OR IGNORE INTO scope(module_pkg_name,app_pkg_name,user_id)"
                                + " VALUES(?,?,0)",
                        new Object[]{module, FRAMEWORK_SCOPE_IN_DB});
                System.out.println("enabled " + module + " -> " + apk);
            } else if ("disable".equals(mode)) {
                String module = args[2];
                db.execSQL("DELETE FROM scope WHERE module_pkg_name=?", new Object[]{module});
                db.execSQL("DELETE FROM modules_state WHERE module_pkg_name=?", new Object[]{module});
                db.execSQL("DELETE FROM modules WHERE module_pkg_name=?", new Object[]{module});
                System.out.println("disabled " + module);
            } else {
                throw new IllegalArgumentException("unknown mode " + mode);
            }
            db.setTransactionSuccessful();
        } finally {
            db.endTransaction();
            db.close();
        }
    }
}
