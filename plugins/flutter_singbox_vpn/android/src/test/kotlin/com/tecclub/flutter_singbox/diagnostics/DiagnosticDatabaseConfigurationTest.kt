package com.tecclub.flutter_singbox.diagnostics

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import org.mockito.Mockito
import kotlin.test.Test

class DiagnosticDatabaseConfigurationTest {
    @Test fun `pragma statements returning rows use query API and close cursors`() {
        for (pageSize in listOf(4096L, 16384L)) {
            val db = Mockito.mock(SQLiteDatabase::class.java)
            val cursor = Mockito.mock(Cursor::class.java)
            Mockito.`when`(db.rawQuery(Mockito.anyString(), Mockito.isNull())).thenReturn(cursor)
            Mockito.`when`(cursor.getLong(0)).thenReturn(pageSize)
            configureDiagnosticDatabase(db)
            Mockito.verify(db).rawQuery("PRAGMA busy_timeout=1000", null)
            Mockito.verify(db).rawQuery("PRAGMA journal_size_limit=1048576", null)
            Mockito.verify(db).rawQuery("PRAGMA wal_autocheckpoint=128", null)
            Mockito.verify(db).rawQuery("PRAGMA max_page_count=${32L * 1024 * 1024 / pageSize}", null)
            Mockito.verify(cursor, Mockito.times(5)).close()
            Mockito.verify(db, Mockito.never()).execSQL(Mockito.anyString())
        }
    }
}
