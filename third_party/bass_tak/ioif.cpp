
// interface wrapper of BASSFILE for tak_deco_lib

#include "bass-addon.h"
#include "tak_deco_lib.h"
#include "ioif.h"

typedef TtakBool(*BoolVoid_Callback)(void*);

// TAK IO functions
TtakBool CanRead(BASSFILE bassFile)
{
	return tak_True;
}

TtakBool CanSeek(BASSFILE bassFile)
{
	return tak_True;
}

TtakBool Read(BASSFILE bassFile, void *ABuf, TtakInt32 ANum, TtakInt32 *AReadNum )
{
	*AReadNum = (TtakInt32)bassfunc->file.Read(bassFile, ABuf, (DWORD)ANum);
	if (*AReadNum > 0) return tak_True;
	return tak_False;
}

TtakBool Write(BASSFILE bassFile, const void *ABuf, TtakInt32 ANum)
{
	return tak_False;
}

TtakBool Seek(BASSFILE bassFile, TtakInt64 APos)
{
	// BASS 2.4 在 64 位下用 64 位文件偏移，截断到 DWORD 会让大文件 seek 到错误位置。
	return bassfunc->file.Seek(bassFile, (QWORD)APos) ? tak_True : tak_False;
}

TtakBool GetLength(BASSFILE bassFile, TtakInt64 *ALength)
{
	*ALength = (TtakInt64)bassfunc->file.GetPos(bassFile, BASS_FILEPOS_END);
	return tak_True;
}

TtakBool always_false(BASSFILE bassFile)
{
	return tak_False;
}

BoolVoid_Callback CanWrite = always_false;
BoolVoid_Callback Flush = always_false;
BoolVoid_Callback Truncate = always_false;

TtakStreamIoInterface IOIF = 
{
	CanRead,
	CanWrite,
	CanSeek,
	Read,
	Write,
	Flush,
	Truncate,
	Seek,
	GetLength,
};
