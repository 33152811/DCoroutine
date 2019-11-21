unit coroutine;

(*
***************************************************************************
 coroutine for Delphi 
 Copyright (c) 2019-2019 zhouzuoji(zhouzouji@outlook.com)
                                                                       
 Permission is hereby granted, free of charge, to any person obtaining 
 a copy of this software and associated documentation files (the       
 "Software"), to deal in the Software without restriction, including   
 without limitation the rights to use, copy, modify, merge, publish,   
 distribute, sublicense, and/or sell copies of the Software, and to    
 permit persons to whom the Software is furnished to do so, subject to 
 the following conditions:                                             
                                                                       
 The above copyright notice and this permission notice shall be        
 included in all copies or substantial portions of the Software.       
                                                                       
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       
 EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF    
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY  
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,  
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE     
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                
***************************************************************************
*)

(**
  coroutine��ʾ, �����˺ܶ�ϸ��, ����:

    ֻ������8��ͨ�üĴ���

    û�б���SEH�쳣������

    ֻʹ��һ������ϵͳ�߳�

    Ĭ��ֻ��ȫ�־�����������(Interlock��ʽ), ��Ϊ�����ж��̲߳�����д

    waiting��running����û����, ��Ϊֻ��һ���̷߳��ʡ�
    �������չΪʹ�ö������ϵͳ�߳�����coroutine, ����������Ҳ��Ҫ���ġ�

    coroutine_currentʹ���˱���running���еķ�������coroutine��Ϊ�˸�����,
    running������Ҫ��Ϊ�����֮������ݽṹ

    coroutine yieldʱ�������лص����߳�, �����Ż�Ϊcoroutine yieldʱ
    ֱ��ת������coroutineִ��
*)

interface

uses
  SysUtils, Classes, Windows, Generics.Collections, Generics.Defaults;

type
  TCoroutineEntryProc = procedure(avParam: Pointer);
  TCoroutineState = (csReady, csRunning, csWaiting, csFinished);

  TRegisterContext = record
    XAX, XBX, XCX, XDX, XSI, XDI, XSP, XBP: Pointer;
  end;

  PCoroutineContext = ^TCoroutineContext;
  TCoroutineContext = record
    regs, HostRegs: TRegisterContext;
    StackBase: Pointer;
    StackSize: NativeInt;
    State, NextState: TCoroutineState;
    EntryProc: TCoroutineEntryProc;
    EntryProcParam: Pointer;
    prior, next: PCoroutineContext;
  end;

  TOverlappedEx = packed record
    _: TOverlapped;
    c: PCoroutineContext;
  end;
  POverlappedEx = ^TOverlappedEx;

procedure RegisterIOCP(h: THandle);

procedure coroutine_create(avProc: TCoroutineEntryProc; avParam: Pointer;
  avStackSize: Integer = 64*1024);

(*
  coroutine_yield, coroutine_wait, coroutine_exit��������coroutineִ�����е��ò���Ч��
  ���ִ��������coroutine, ��������������û���κ�Ч����
*)

// �ó�ִ��Ȩ(�����������)
procedure coroutine_yield;

procedure coroutine_wait(c: PCoroutineContext);

(* ��ֹcoroutine *)
procedure coroutine_exit;

(* ��õ�ǰִ�������ڵ�coroutine *)
function coroutine_current: PCoroutineContext;

implementation

var
  gRunningLock: Integer = 0;
  gIOCP: THandle;
  gWaitingQueue: TCoroutineContext;
  gReadyQueue: TCoroutineContext;
  gRunningQueue: TCoroutineContext;
  gTerminate: Boolean = False;

function allocStack(avSize: Integer): Pointer; forward;
procedure FreeStack(avBase: Pointer); forward;
function getRunningCoroutine(avESP: Pointer): PCoroutineContext; forward;
procedure extractRunning(c: PCoroutineContext); forward;
procedure markRunning(c: PCoroutineContext); forward;

procedure markReady(c: PCoroutineContext); forward;

// ��ȫ�־���������ȡcoroutine
function PopGlobalReady: PCoroutineContext; forward;

procedure markWaiting(c: PCoroutineContext); forward;

procedure extractWaiting(c: PCoroutineContext); forward;

// ʵ�ʵ�coroutine��ں���, �൱��C��main
procedure coroutineMain(c: PCoroutineContext); forward;

// �ָ�������coroutineִ��
procedure resumeCoroutine(c: PCoroutineContext); forward;

type
  TCoroutineThread = class(TThread)
  private
    FReadyQueue: TCoroutineContext;
    function PopReady: PCoroutineContext;
    procedure CheckIO;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
  end;

procedure RegisterIOCP(h: THandle);
begin
  CreateIoCompletionPort(h, gIOCP, h, 0);
end;

procedure schedule;
begin

end;

function coroutine_current: PCoroutineContext; assembler;
asm
  mov eax, esp
  call getRunningCoroutine
end;

procedure coroutine_create(avProc: TCoroutineEntryProc; avParam: Pointer; avStackSize: Integer);
var
  c: PCoroutineContext;
  pp: PPointer;
begin
  if avStackSize < 0 then
    avStackSize := 64*1024;
  New(c);
  c.StackSize := avStackSize;
  c.StackBase := allocStack(avStackSize);
  c.EntryProc := avProc;
  c.EntryProcParam := avParam;
  pp := Pointer(NativeInt(c.StackBase) + c.StackSize);
  c.regs.XBP := pp;
  c.regs.XAX := c; // coroutineMain.c
  Dec(pp);
  pp^ := @coroutineMain;
  c.regs.XSP := pp;
  markReady(c);
end;

procedure coroutine_destroy(c: PCoroutineContext);
begin
  freeStack(c.StackBase);
  Dispose(c);
end;

procedure _coroutine_yield(c: PCoroutineContext); forward;

procedure coroutine_yield; assembler;
asm
  mov eax, esp
  call getRunningCoroutine
  mov [eax].TCoroutineContext.NextState, csReady;
  jne _coroutine_yield
end;

procedure coroutine_wait(c: PCoroutineContext); assembler;
asm
  mov [eax].TCoroutineContext.NextState, csWaiting;
  jmp _coroutine_yield
end;

procedure coroutine_exit; assembler;
asm
  mov eax, esp
  call getRunningCoroutine
  je @exit
  mov [eax].TCoroutineContext.NextState, csFinished
  (* �ָ��̼߳Ĵ��� *)
  mov ebx, [eax].TCoroutineContext.HostRegs.XBX
  mov ecx, [eax].TCoroutineContext.HostRegs.XCX
  mov edx, [eax].TCoroutineContext.HostRegs.XDX
  mov esi, [eax].TCoroutineContext.HostRegs.XSI
  mov edi, [eax].TCoroutineContext.HostRegs.XDI
  mov esp, [eax].TCoroutineContext.HostRegs.XSP
  mov ebp, [eax].TCoroutineContext.HostRegs.XBP
  mov eax, [eax].TCoroutineContext.HostRegs.XAX
@exit:
end;

{ TCoroutineThread }

procedure TCoroutineThread.CheckIO;
var
  lvBytesTransferred: Cardinal;
  lpCompletionKey: ULONG_PTR;
  lvOverlapped: POverlappedEx;
begin
  while True do
  begin
    lvOverlapped := nil;
    lvBytesTransferred := 0;
    lpCompletionKey := 0;
    if GetQueuedCompletionStatus(gIOCP, lvBytesTransferred, lpCompletionKey, POverlapped(lvOverlapped), 0) then
    begin
      while lvOverlapped.c.State <> TCoroutineState.csWaiting do;
      extractWaiting(lvOverlapped.c);
      markReady(lvOverlapped.c);
    end
    else if Assigned(lvOverlapped) then
    begin
      while lvOverlapped.c.State <> TCoroutineState.csWaiting do;
      extractWaiting(lvOverlapped.c);
      markReady(lvOverlapped.c);
    end
    else Break;
  end;
end;

constructor TCoroutineThread.Create;
begin
  FReadyQueue.next := @FReadyQueue;
  FReadyQueue.prior := @FReadyQueue;
  FreeOnTerminate := True;
  inherited Create(False);
end;

destructor TCoroutineThread.Destroy;
begin
  inherited;
end;

procedure TCoroutineThread.Execute;
var
  c: PCoroutineContext;
begin
  inherited;
  while not gTerminate do
  begin
    c := PopReady;
    if not Assigned(c) then
    begin
      CheckIO;
      Continue;
    end;

    markRunning(c);
    resumeCoroutine(c);
    extractRunning(c);
    case c.NextState of
      csReady, csRunning: markReady(c);
      csWaiting: markWaiting(c);
      csFinished: coroutine_destroy(c);
    end;
  end;
end;

function TCoroutineThread.PopReady: PCoroutineContext;
begin
  Result := FReadyQueue.next;
  if Result <> @FReadyQueue then
  begin
    FReadyQueue.next := Result.next;
    Result.next.prior := @FReadyQueue;
  end
  else
    Result := PopGlobalReady;
end;

function allocStack(avSize: Integer): Pointer;
begin
  Result := GetMemory(avSize);
end;

procedure FreeStack(avBase: Pointer);
begin
  FreeMemory(avBase);
end;

// never return
procedure coroutineMain(c: PCoroutineContext);
var
  t: DWORD;
begin
  t := GetTickCount;
  c.EntryProc(c.EntryProcParam);
  Writeln('coroutine ran for ', GetTickCount - t, ' ms');
  coroutine_exit;
end;

procedure resumeCoroutine(c: PCoroutineContext); assembler;
asm
  // �����̼߳Ĵ���
  mov [eax].TCoroutineContext.HostRegs.XBX, ebx
  mov [eax].TCoroutineContext.HostRegs.XCX, ecx
  mov [eax].TCoroutineContext.HostRegs.XDX, edx
  mov [eax].TCoroutineContext.HostRegs.XSI, esi
  mov [eax].TCoroutineContext.HostRegs.XDI, edi
  mov [eax].TCoroutineContext.HostRegs.XSP, esp
  mov [eax].TCoroutineContext.HostRegs.XBP, ebp
  mov [eax].TCoroutineContext.HostRegs.XAX, eax

  // �ָ�coroutine�Ĵ���
  mov ebx, [eax].TCoroutineContext.regs.XBX
  mov ecx, [eax].TCoroutineContext.regs.XCX
  mov edx, [eax].TCoroutineContext.regs.XDX
  mov esi, [eax].TCoroutineContext.regs.XSI
  mov edi, [eax].TCoroutineContext.regs.XDI
  mov esp, [eax].TCoroutineContext.regs.XSP
  mov ebp, [eax].TCoroutineContext.regs.XBP
  mov eax, [eax].TCoroutineContext.regs.XAX
end;

procedure _coroutine_yield(c: PCoroutineContext); assembler;
asm
  (* ����coroutine �Ĵ��� *)
  mov [eax].TCoroutineContext.regs.XBX, ebx
  mov [eax].TCoroutineContext.regs.XCX, ecx
  mov [eax].TCoroutineContext.regs.XDX, edx
  mov [eax].TCoroutineContext.regs.XSI, esi
  mov [eax].TCoroutineContext.regs.XDI, edi
  mov [eax].TCoroutineContext.regs.XSP, esp
  mov [eax].TCoroutineContext.regs.XBP, ebp
  mov [eax].TCoroutineContext.regs.XAX, eax

  (* �ָ��̼߳Ĵ��� *)
  mov ebx, [eax].TCoroutineContext.HostRegs.XBX
  mov ecx, [eax].TCoroutineContext.HostRegs.XCX
  mov edx, [eax].TCoroutineContext.HostRegs.XDX
  mov esi, [eax].TCoroutineContext.HostRegs.XSI
  mov edi, [eax].TCoroutineContext.HostRegs.XDI
  mov esp, [eax].TCoroutineContext.HostRegs.XSP
  mov ebp, [eax].TCoroutineContext.HostRegs.XBP
  mov eax, [eax].TCoroutineContext.HostRegs.XAX
@exit:
end;

procedure extractRunning(c: PCoroutineContext);
begin
  c.next.prior := c.prior;
  c.prior.next := c.next;
end;

procedure markRunning(c: PCoroutineContext);
begin
  c.State := TCoroutineState.csRunning;
  gRunningQueue.prior.next := c;
  c.prior := gRunningQueue.prior;
  c.next := @gRunningQueue;
  gRunningQueue.prior := c;
end;

procedure markReady(c: PCoroutineContext);
begin
  while InterlockedExchange(gRunningLock, 1) = 1 do;
  gReadyQueue.prior.next := c;
  c.prior := gReadyQueue.prior;
  c.next := @gReadyQueue;
  gReadyQueue.prior := c;
  c.State := TCoroutineState.csReady;
  InterlockedExchange(gRunningLock, 0);
end;

function PopGlobalReady: PCoroutineContext;
begin
  while InterlockedExchange(gRunningLock, 1) = 1 do;
  Result := gReadyQueue.next;
  if Result <> @gReadyQueue then
  begin
    gReadyQueue.next := Result.next;
    Result.next.prior := @gReadyQueue;
  end
  else
    Result := nil;
  InterlockedExchange(gRunningLock, 0);
end;

procedure markWaiting(c: PCoroutineContext);
begin
  gWaitingQueue.prior.next := c;
  c.prior := gWaitingQueue.prior;
  c.next := @gWaitingQueue;
  gWaitingQueue.prior := c;
  c.State := TCoroutineState.csWaiting;
end;

procedure extractWaiting(c: PCoroutineContext);
begin
  c.next.prior := c.prior;
  c.prior.next := c.next;
end;

function getRunningCoroutine(avESP: Pointer): PCoroutineContext;
var
  c: PCoroutineContext;
begin
  c := gRunningQueue.next;
  while c <> @gRunningQueue do
  begin
    if (NativeInt(avESP) > NativeInt(c.StackBase)) and (NativeInt(avESP) < NativeInt(c.StackBase) + c.StackSize) then
      Exit(c);
    c := c.next;
  end;
  Result := nil;
end;

procedure ClearCoroutines;
begin
  gTerminate := True;
  Sleep(2000);
end;

initialization
  gReadyQueue.prior := @gReadyQueue;
  gReadyQueue.next := @gReadyQueue;
  gRunningQueue.prior := @gRunningQueue;
  gRunningQueue.next := @gRunningQueue;
  gWaitingQueue.prior := @gWaitingQueue;
  gWaitingQueue.next := @gWaitingQueue;
  gIOCP := CreateIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 0);
  TCoroutineThread.Create;

finalization
  ClearCoroutines;

end.
