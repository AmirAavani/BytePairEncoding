unit BPE.Trainer;

{$mode objfpc}{$H+}{$J-}

interface

uses
  BPE.Core;

type
  TBPETrainer = class
  public
    class function Train(const ATokenFreqMap: TTokenFrequency;
      AVocabSize: integer; const ASpecialTokens: array of string): TBPEConfig;
  end;

implementation

uses
  Classes, SysUtils, Generics.Collections, ALoggerUnit;

type
  { =========================================================================
    INTERNAL DATA STRUCTURES
    ========================================================================= }

  TSequenceNode = record
    TokenID: TTokenID;
    IsSpecial: boolean;
    Prev: integer;
    Next: integer;
  end;

  TSequenceArray = array of TSequenceNode;

  TWordEntry = class
  public
    WordStr: ansistring;
    Count: uint64;
    Nodes: TSequenceArray;
    Head: integer;
    constructor Create(const AWordStr: ansistring; ACount: uint64);
  end;

  THeapNode = record
    PairKey: QWord;
    Freq: uint64;
  end;

  TMaxHeap = class
  private
    FData: array of THeapNode;
    FCount: integer;
    procedure SiftUp(Index: integer);
    procedure SiftDown(Index: integer);
  public
    constructor Create;
    procedure Push(APairKey: QWord; AFreq: uint64);
    function Pop(out APairKey: QWord; out AFreq: uint64): boolean;
    property Count: integer read FCount;
  end;

  { =========================================================================
    INTERNAL ENGINE
    ========================================================================= }

  TBPETrainerEngine = class
  private
    FSpecialTokens: TStringList;
    FTokenToID: TBPEConfig.TTokenToID;
    FIDToToken: TBPEConfig.TIDToToken;
    FSpecialTokenMap: TBPEConfig.TSpecialTokenMap;
    FNextID: TTokenID;
    FByteOffset: integer;
    FMerges: TBPEConfig.TBPEPairMergeList;

    procedure AddSpecialToken(const AToken: string);
    procedure InitializeVocabulary;
    procedure PopulateBaseVocabulary(const ATokenFreqMap: TTokenFrequency);

    function PackPair(LeftID, RightID: TTokenID): QWord; inline;
    procedure UnpackPair(PairKey: QWord; out LeftID, RightID: TTokenID); inline;

    procedure BuildWordEntries(const ATokenFreqMap: TTokenFrequency;
      out Words: specialize TObjectList<TWordEntry>);

    procedure RunMergeLoop(Words: specialize TObjectList<TWordEntry>;
      AVocabSize: integer);

    function ExportConfig: TBPEConfig;
  public
    constructor Create;
    destructor Destroy; override;

    function Execute(const ATokenFreqMap: TTokenFrequency;
      AVocabSize: integer; const ASpecialTokens: array of string): TBPEConfig;
  end;

{ =========================================================================
  IMPLEMENTATIONS
  ========================================================================= }

  { TWordEntry }

constructor TWordEntry.Create(const AWordStr: ansistring; ACount: uint64);
begin
  inherited Create;
  WordStr := AWordStr;
  Count := ACount;
  Head := 0;
end;

{ TMaxHeap }

constructor TMaxHeap.Create;
begin
  FCount := 0;
  SetLength(FData, 1024);
end;

procedure TMaxHeap.SiftUp(Index: integer);
var
  ParentIdx: integer;
  Temp: THeapNode;
begin
  while Index > 0 do
  begin
    ParentIdx := (Index - 1) div 2;
    if FData[Index].Freq <= FData[ParentIdx].Freq then Break;

    Temp := FData[Index];
    FData[Index] := FData[ParentIdx];
    FData[ParentIdx] := Temp;
    Index := ParentIdx;
  end;
end;

procedure TMaxHeap.SiftDown(Index: integer);
var
  MaxChild, LeftChild, RightChild: integer;
  Temp: THeapNode;
begin
  while (2 * Index + 1) < FCount do
  begin
    LeftChild := 2 * Index + 1;
    RightChild := 2 * Index + 2;
    MaxChild := LeftChild;

    if (RightChild < FCount) and (FData[RightChild].Freq > FData[LeftChild].Freq) then
      MaxChild := RightChild;

    if FData[Index].Freq >= FData[MaxChild].Freq then Break;

    Temp := FData[Index];
    FData[Index] := FData[MaxChild];
    FData[MaxChild] := Temp;
    Index := MaxChild;
  end;
end;

procedure TMaxHeap.Push(APairKey: QWord; AFreq: uint64);
begin
  if FCount = Length(FData) then
    SetLength(FData, Length(FData) * 2);

  FData[FCount].PairKey := APairKey;
  FData[FCount].Freq := AFreq;
  Inc(FCount);
  SiftUp(FCount - 1);
end;

function TMaxHeap.Pop(out APairKey: QWord; out AFreq: uint64): boolean;
begin
  if FCount = 0 then Exit(False);

  APairKey := FData[0].PairKey;
  AFreq := FData[0].Freq;

  Dec(FCount);
  if FCount > 0 then
  begin
    FData[0] := FData[FCount];
    SiftDown(0);
  end;
  Result := True;
end;

{ TBPETrainerEngine }

constructor TBPETrainerEngine.Create;
begin
  inherited Create;
  FSpecialTokens := TStringList.Create;
  FTokenToID := TBPEConfig.TTokenToID.Create;
  FIDToToken := TBPEConfig.TIDToToken.Create;
  FSpecialTokenMap := TBPEConfig.TSpecialTokenMap.Create;
  FMerges := TBPEConfig.TBPEPairMergeList.Create;
  FNextID := 0;
  FByteOffset := 0;
end;

destructor TBPETrainerEngine.Destroy;
begin
  FSpecialTokens.Free;
  FTokenToID.Free;
  FIDToToken.Free;
  FSpecialTokenMap.Free;
  FMerges.Free;
  inherited Destroy;
end;

procedure TBPETrainerEngine.AddSpecialToken(const AToken: string);
begin
  if FSpecialTokens.IndexOf(AToken) = -1 then
    FSpecialTokens.Add(AToken);
end;

procedure TBPETrainerEngine.InitializeVocabulary;
var
  i: integer;
  TokenStr: ansistring;
begin
  FTokenToID.Clear;
  FIDToToken.Clear;
  FSpecialTokenMap.Clear;
  FNextID := 0;

  for i := 0 to FSpecialTokens.Count - 1 do
  begin
    TokenStr := FSpecialTokens[i];
    FTokenToID.Add(TokenStr, FNextID);
    FIDToToken.Add(FNextID, TokenStr);
    FSpecialTokenMap.Add(TokenStr, FNextID);
    Inc(FNextID);
  end;
  FByteOffset := FNextID;
end;

procedure TBPETrainerEngine.PopulateBaseVocabulary(const ATokenFreqMap: TTokenFrequency);
var
  b: byte;
  ByteStr: ansistring;
begin
  for b := 0 to 255 do
  begin
    ByteStr := Chr(b);
    if not FTokenToID.ContainsKey(ByteStr) then
    begin
      FTokenToID.Add(ByteStr, FByteOffset + b);
      FIDToToken.Add(FByteOffset + b, ByteStr);
    end;
  end;
  FNextID := FByteOffset + 256;
end;

function TBPETrainerEngine.PackPair(LeftID, RightID: TTokenID): QWord;
begin
  Result := (QWord(cardinal(LeftID)) shl 32) or QWord(cardinal(RightID));
end;

procedure TBPETrainerEngine.UnpackPair(PairKey: QWord; out LeftID, RightID: TTokenID);
begin
  LeftID := TTokenID(PairKey shr 32);
  RightID := TTokenID(PairKey and $FFFFFFFF);
end;

procedure TBPETrainerEngine.BuildWordEntries(const ATokenFreqMap: TTokenFrequency;
  out Words: specialize TObjectList<TWordEntry>);
var
  Pair: specialize TPair<ansistring, uint64>;
  WordEntry: TWordEntry;
  i, Len: integer;
  ByteVal: byte;
  ByteStr: ansistring;
begin
  Words := (specialize TObjectList<TWordEntry>).Create(True);

  for Pair in ATokenFreqMap do
  begin
    Len := Length(Pair.Key);
    if Len = 0 then Continue;

    WordEntry := TWordEntry.Create(Pair.Key, Pair.Value);
    SetLength(WordEntry.Nodes, Len);

    for i := 1 to Len do
    begin
      ByteVal := Ord(Pair.Key[i]);
      ByteStr := Chr(ByteVal);

      WordEntry.Nodes[i - 1].TokenID := FByteOffset + ByteVal;
      WordEntry.Nodes[i - 1].IsSpecial := FSpecialTokenMap.ContainsKey(ByteStr);
      WordEntry.Nodes[i - 1].Prev := i - 2;
      WordEntry.Nodes[i - 1].Next := i;
    end;
    WordEntry.Nodes[Len - 1].Next := -1;
    Words.Add(WordEntry);
  end;
end;

procedure TBPETrainerEngine.RunMergeLoop(Words: specialize TObjectList<TWordEntry>;
  AVocabSize: integer);
type
  TWordList = specialize TList<integer>;
  TPairToWords = specialize TDictionary<QWord, TWordList>;
  TPairFreqMap = specialize TDictionary<QWord, uint64>;
var
  PairFreqs: TPairFreqMap;
  PairToWords: TPairToWords;
  Heap: TMaxHeap;
  WordIdx, CurrIdx, NextIdx, PrevIdx, NextNextIdx: integer;
  PairKey, OldPair, NewPair, BestPairKey: QWord;
  HeapFreq, CurrentFreq: uint64;
  BestLeftID, BestRightID: TTokenID;
  MergedTokenStr: ansistring;
  NewTokenID: TTokenID;
  MergedPair: TBPEConfig.TBPEPairMerge;
  WordProcessed: array of integer;
  Pair: specialize TPair<QWord, uint64>;
  WL: TWordList;
  w: integer;
begin
  PairFreqs := TPairFreqMap.Create;
  PairToWords := TPairToWords.Create;
  Heap := TMaxHeap.Create;
  SetLength(WordProcessed, Words.Count);
  for WordIdx := 0 to Words.Count - 1 do WordProcessed[WordIdx] := -1;

  for WordIdx := 0 to Words.Count - 1 do
  begin
    CurrIdx := Words[WordIdx].Head;
    while CurrIdx <> -1 do
    begin
      NextIdx := Words[WordIdx].Nodes[CurrIdx].Next;
      if (NextIdx <> -1) and not Words[WordIdx].Nodes[CurrIdx].IsSpecial and
        not Words[WordIdx].Nodes[NextIdx].IsSpecial then
      begin
        PairKey := PackPair(Words[WordIdx].Nodes[CurrIdx].TokenID,
          Words[WordIdx].Nodes[NextIdx].TokenID);

        if PairFreqs.TryGetValue(PairKey, CurrentFreq) then
          PairFreqs.AddOrSetValue(PairKey, CurrentFreq + Words[WordIdx].Count)
        else
          PairFreqs.Add(PairKey, Words[WordIdx].Count);

        if not PairToWords.TryGetValue(PairKey, WL) then
        begin
          WL := TWordList.Create;
          PairToWords.Add(PairKey, WL);
        end;
        WL.Add(WordIdx);
      end;
      CurrIdx := NextIdx;
    end;
  end;

  for Pair in PairFreqs do Heap.Push(Pair.Key, Pair.Value);

  while FNextID < TTokenID(AVocabSize) do
  begin
    if not Heap.Pop(BestPairKey, HeapFreq) then Break;
    if (not PairFreqs.TryGetValue(BestPairKey, CurrentFreq)) or
      (HeapFreq <> CurrentFreq) then Continue;
    if CurrentFreq <= 1 then Break;

    UnpackPair(BestPairKey, BestLeftID, BestRightID);

    MergedTokenStr := FIDToToken[BestLeftID] + FIDToToken[BestRightID];
    NewTokenID := FNextID;
    Inc(FNextID);

    FTokenToID.Add(MergedTokenStr, NewTokenID);
    FIDToToken.Add(NewTokenID, MergedTokenStr);

    MergedPair.LeftToken := BestLeftID;
    MergedPair.RightToken := BestRightID;
    MergedPair.NewTokenId := NewTokenID;
    FMerges.Add(MergedPair);

    WL := PairToWords[BestPairKey];
    for w := 0 to WL.Count - 1 do
    begin
      WordIdx := WL[w];
      if WordProcessed[WordIdx] = integer(FNextID) then Continue;
      WordProcessed[WordIdx] := integer(FNextID);

      CurrIdx := Words[WordIdx].Head;
      while CurrIdx <> -1 do
      begin
        NextIdx := Words[WordIdx].Nodes[CurrIdx].Next;
        if (NextIdx <> -1) and (Words[WordIdx].Nodes[CurrIdx].TokenID =
          BestLeftID) and (Words[WordIdx].Nodes[NextIdx].TokenID = BestRightID) and
          not Words[WordIdx].Nodes[CurrIdx].IsSpecial and not
          Words[WordIdx].Nodes[NextIdx].IsSpecial then
        begin
          PrevIdx := Words[WordIdx].Nodes[CurrIdx].Prev;
          NextNextIdx := Words[WordIdx].Nodes[NextIdx].Next;

          if (PrevIdx <> -1) and not Words[WordIdx].Nodes[PrevIdx].IsSpecial then
          begin
            OldPair := PackPair(Words[WordIdx].Nodes[PrevIdx].TokenID, BestLeftID);
            PairFreqs[OldPair] := PairFreqs[OldPair] - Words[WordIdx].Count;
            Heap.Push(OldPair, PairFreqs[OldPair]);
          end;

          if (NextNextIdx <> -1) and not
            Words[WordIdx].Nodes[NextNextIdx].IsSpecial then
          begin
            OldPair := PackPair(BestRightID,
              Words[WordIdx].Nodes[NextNextIdx].TokenID);
            PairFreqs[OldPair] := PairFreqs[OldPair] - Words[WordIdx].Count;
            Heap.Push(OldPair, PairFreqs[OldPair]);
          end;

          Words[WordIdx].Nodes[CurrIdx].TokenID := NewTokenID;
          Words[WordIdx].Nodes[CurrIdx].Next := NextNextIdx;
          if NextNextIdx <> -1 then
            Words[WordIdx].Nodes[NextNextIdx].Prev := CurrIdx;

          if (PrevIdx <> -1) and not Words[WordIdx].Nodes[PrevIdx].IsSpecial then
          begin
            NewPair := PackPair(Words[WordIdx].Nodes[PrevIdx].TokenID, NewTokenID);
            if PairFreqs.TryGetValue(NewPair, CurrentFreq) then
              PairFreqs[NewPair] := CurrentFreq + Words[WordIdx].Count
            else
              PairFreqs.Add(NewPair, Words[WordIdx].Count);

            Heap.Push(NewPair, PairFreqs[NewPair]);

            if not PairToWords.ContainsKey(NewPair) then
              PairToWords.Add(NewPair, TWordList.Create);
            PairToWords[NewPair].Add(WordIdx);
          end;

          if (NextNextIdx <> -1) and not
            Words[WordIdx].Nodes[NextNextIdx].IsSpecial then
          begin
            NewPair := PackPair(NewTokenID, Words[WordIdx].Nodes[NextNextIdx].TokenID);
            if PairFreqs.TryGetValue(NewPair, CurrentFreq) then
              PairFreqs[NewPair] := CurrentFreq + Words[WordIdx].Count
            else
              PairFreqs.Add(NewPair, Words[WordIdx].Count);

            Heap.Push(NewPair, PairFreqs[NewPair]);

            if not PairToWords.ContainsKey(NewPair) then
              PairToWords.Add(NewPair, TWordList.Create);
            PairToWords[NewPair].Add(WordIdx);
          end;

          CurrIdx := NextNextIdx;
        end
        else
          CurrIdx := NextIdx;
      end;
    end;

    PairFreqs.Remove(BestPairKey);

    if FNextID mod 1000 = 0 then
      WriteLn(Format('Merged %d tokens. Current max freq: %d', [FNextID, HeapFreq]));
  end;

  for PairKey in PairToWords.Keys do
    PairToWords[PairKey].Free;

  PairToWords.Free;
  PairFreqs.Free;
  Heap.Free;
end;

function TBPETrainerEngine.ExportConfig: TBPEConfig;
var
  Pair: specialize TPair<ansistring, TTokenID>;
  SpecPair: specialize TPair<ansistring, TTokenID>;
  MergePair: TBPEConfig.TBPEPairMerge;
begin
  FMTDebugLn('ExportConfig', []);
  Result := TBPEConfig.Create;
  Result.VocabSize := FNextID;
  Result.ByteOffset := FByteOffset;
  FMTDebugLn('ExportConfig.2', []);

  for SpecPair in FSpecialTokenMap do
    Result.SpecialTokens.Add(SpecPair.Key, SpecPair.Value);
  FMTDebugLn('ExportConfig.3', []);

  for Pair in FTokenToID do
  begin
    Result.TokenToID.Add(Pair.Key, Pair.Value);
    Result.IDToToken.Add(Pair.Value, Pair.Key);
  end;
  FMTDebugLn('ExportConfig.4', []);

  for MergePair in FMerges do
    Result.Merges.Add(MergePair);
  FMTDebugLn('ExportConfig.5', []);

end;

function TBPETrainerEngine.Execute(const ATokenFreqMap: TTokenFrequency;
  AVocabSize: integer; const ASpecialTokens: array of string): TBPEConfig;
var
  Words: specialize TObjectList<TWordEntry>;
  i: integer;
begin
  Words := nil;
  for i := Low(ASpecialTokens) to High(ASpecialTokens) do
    AddSpecialToken(ASpecialTokens[i]);

  InitializeVocabulary;
  PopulateBaseVocabulary(ATokenFreqMap);
  BuildWordEntries(ATokenFreqMap, Words);
  RunMergeLoop(Words, AVocabSize);

  Result := ExportConfig;
  Words.Free;
end;

class function TBPETrainer.Train(const ATokenFreqMap: TTokenFrequency;
  AVocabSize: integer; const ASpecialTokens: array of string): TBPEConfig;
var
  Engine: TBPETrainerEngine;
begin
  Engine := TBPETrainerEngine.Create;
  Result := Engine.Execute(ATokenFreqMap, AVocabSize, ASpecialTokens);
  Engine.Free;
end;

end.
