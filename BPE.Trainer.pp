unit BPE.Trainer;

{$MODE OBJFPC}{$H+}{$J-}
{$modeswitch ADVANCEDRECORDS}

interface

uses
  BPE.Core;

type
  { TBPETrainer }
  // Pure static utility that executes BPE training and returns a TBPEConfig instance.
  TBPETrainer = class
  public
    class function Train(WordCounts: TWordDictionary; TargetVocabSize: integer;
      const ReservedSpecialTokens: array of string): TBPEConfig;
  end;


implementation

uses
  Generics.Collections;

type
  TIntegerList = specialize TList<integer>;
  TPairCountMap = specialize TDictionary<TTokenPair, integer>;
  TPairIndexMap = specialize TDictionary<TTokenPair, TIntegerList>;

  { TWordItem }

  TWordItem = class
  public
    Tokens: TIntegerList;
    Count: integer;
    constructor Create(AFreq: integer);
    destructor Destroy; override;
  end;



  { TMaxHeap and Internal Context }

type
  THeapNode = record
    Pair: TTokenPair;
    Freq: integer;
  end;

  TMaxHeap = class
  private
    FData: array of THeapNode;
    FCount: integer;
    procedure SiftUp(Index: integer);
    procedure SiftDown(Index: integer);
  public
    constructor Create;
    procedure Push(const APair: TTokenPair; AFreq: integer);
    function Pop(out APair: TTokenPair; out AFreq: integer): boolean;
  end;


  { TTrainContext }

  TTrainContext = record
    Words: specialize TObjectList<TWordItem>;
    PairCounts: TPairCountMap;
    PairIndex: TPairIndexMap;
    Heap: TMaxHeap;
    procedure UpdatePairCount(const Pair: TTokenPair; Delta: integer; WordIdx: integer);
  end;

constructor TMaxHeap.Create;
begin
  SetLength(FData, 64);
  FCount := 0;
end;

procedure TMaxHeap.Push(const APair: TTokenPair; AFreq: integer);
begin
  if FCount >= Length(FData) then SetLength(FData, Length(FData) * 2);
  FData[FCount].Pair := APair;
  FData[FCount].Freq := AFreq;
  SiftUp(FCount);
  Inc(FCount);
end;

procedure TMaxHeap.SiftUp(Index: integer);
var
  Parent: integer;
  Temp: THeapNode;
begin
  while Index > 0 do
  begin
    Parent := (Index - 1) div 2;
    if FData[Index].Freq <= FData[Parent].Freq then Break;
    Temp := FData[Index];
    FData[Index] := FData[Parent];
    FData[Parent] := Temp;
    Index := Parent;
  end;
end;

procedure TMaxHeap.SiftDown(Index: integer);
var
  Left, Right, MaxIdx: integer;
  Temp: THeapNode;
begin
  while True do
  begin
    Left := 2 * Index + 1;
    Right := 2 * Index + 2;
    MaxIdx := Index;
    if (Left < FCount) and (FData[Left].Freq > FData[MaxIdx].Freq) then MaxIdx := Left;
    if (Right < FCount) and (FData[Right].Freq > FData[MaxIdx].Freq) then
      MaxIdx := Right;
    if MaxIdx = Index then Break;
    Temp := FData[Index];
    FData[Index] := FData[MaxIdx];
    FData[MaxIdx] := Temp;
    Index := MaxIdx;
  end;
end;

function TMaxHeap.Pop(out APair: TTokenPair; out AFreq: integer): boolean;
begin
  if FCount = 0 then Exit(False);
  APair := FData[0].Pair;
  AFreq := FData[0].Freq;
  Dec(FCount);
  if FCount > 0 then
  begin
    FData[0] := FData[FCount];
    SiftDown(0);
  end;
  Result := True;
end;


{ TTrainContext }

procedure TTrainContext.UpdatePairCount(const Pair: TTokenPair;
  Delta: integer; WordIdx: integer);
var
  NewCount: integer;
  IdxList: TIntegerList;
begin
  if Delta = 0 then Exit;

  if PairCounts.TryGetValue(Pair, NewCount) then
    NewCount := NewCount + Delta
  else
    NewCount := Delta;

  if NewCount <= 0 then
    PairCounts.Remove(Pair)
  else
  begin
    PairCounts.AddOrSetValue(Pair, NewCount);
    if Delta > 0 then Heap.Push(Pair, NewCount);
  end;

  if WordIdx >= 0 then
  begin
    if not PairIndex.TryGetValue(Pair, IdxList) then
    begin
      IdxList := TIntegerList.Create;
      PairIndex.Add(Pair, IdxList);
      IdxList.Add(WordIdx);
    end
    else if (IdxList.Count = 0) or (IdxList[IdxList.Count - 1] <> WordIdx) then
      IdxList.Add(WordIdx);
  end;
end;

{ TWordItem }

constructor TWordItem.Create(AFreq: integer);
begin
  Count := AFreq;
  Tokens := TIntegerList.Create;
end;

destructor TWordItem.Destroy;
begin
  Tokens.Free;
  inherited;
end;


{ TBPETrainer }

class function TBPETrainer.Train(WordCounts: TWordDictionary;
  TargetVocabSize: integer; const ReservedSpecialTokens: array of string): TBPEConfig;
var
  Ctx: TTrainContext;
  WordStr: string;
  Freq, i, j, NextTokenId: integer;
  WordItem: TWordItem;
  Pair, HeapPair: TTokenPair;
  HeapFreq, ActualFreq: integer;
  TargetLeft, TargetRight: integer;
  WordIdx: integer;
  Tokens, AffectedWords, IdxList: TIntegerList;
  MergeRule: TBPEPairMerge;
begin
  Result := TBPEConfig.Create;
  Result.VocabSize := TargetVocabSize;
  NextTokenId := 0;

  for i := Low(ReservedSpecialTokens) to High(ReservedSpecialTokens) do
  begin
    Result.SpecialTokens.Add(ReservedSpecialTokens[i], NextTokenId);
    Inc(NextTokenId);
  end;

  Result.ByteOffset := NextTokenId;

  Ctx.Words := specialize TObjectList<TWordItem>.Create(True);
  Ctx.PairCounts := TPairCountMap.Create;
  Ctx.PairIndex := TPairIndexMap.Create;
  Ctx.Heap := TMaxHeap.Create;

  // Populate words using shifted byte IDs
  for WordStr in WordCounts.Keys do
  begin
    Freq := WordCounts[WordStr];
    WordItem := TWordItem.Create(Freq);

    for i := 1 to Length(WordStr) do
      WordItem.Tokens.Add(Result.ByteOffset + Ord(WordStr[i]));

    WordIdx := Ctx.Words.Add(WordItem);

    for i := 0 to WordItem.Tokens.Count - 2 do
    begin
      Pair := MakePair(WordItem.Tokens[i], WordItem.Tokens[i + 1]);
      Ctx.UpdatePairCount(Pair, Freq, WordIdx);
    end;
  end;

  NextTokenId := Result.ByteOffset + 256;

  for Pair in Ctx.PairCounts.Keys do
    Ctx.Heap.Push(Pair, Ctx.PairCounts[Pair]);

  // 3. Execution Loop
  while NextTokenId < TargetVocabSize do
  begin
    ActualFreq := 0;
    while Ctx.Heap.Pop(HeapPair, HeapFreq) do
    begin
      if Ctx.PairCounts.TryGetValue(HeapPair, ActualFreq) and
        (ActualFreq = HeapFreq) then
        Break;
      ActualFreq := 0;
    end;

    if ActualFreq = 0 then Break;

    SplitPair(HeapPair, TargetLeft, TargetRight);
    MergeRule.LeftToken := TargetLeft;
    MergeRule.RightToken := TargetRight;
    MergeRule.NewTokenId := NextTokenId;
    Result.Merges.Add(MergeRule);

    AffectedWords := Ctx.PairIndex[HeapPair];

    for j := 0 to AffectedWords.Count - 1 do
    begin
      WordIdx := AffectedWords[j];
      WordItem := Ctx.Words[WordIdx];
      Tokens := WordItem.Tokens;
      Freq := WordItem.Count;

      i := 0;
      while i < Tokens.Count - 1 do
      begin
        if (Tokens[i] = TargetLeft) and (Tokens[i + 1] = TargetRight) then
        begin
          if i > 0 then
            Ctx.UpdatePairCount(MakePair(Tokens[i - 1], Tokens[i]), -Freq, -1);
          if i < Tokens.Count - 2 then
            Ctx.UpdatePairCount(MakePair(Tokens[i + 1], Tokens[i + 2]), -Freq, -1);

          Tokens[i] := NextTokenId;
          Tokens.Delete(i + 1);

          if i > 0 then
            Ctx.UpdatePairCount(MakePair(Tokens[i - 1], Tokens[i]), Freq, WordIdx);
          if i < Tokens.Count - 1 then
            Ctx.UpdatePairCount(MakePair(Tokens[i], Tokens[i + 1]), Freq, WordIdx);
        end;
        Inc(i);
      end;
    end;

    Ctx.PairCounts.Remove(HeapPair);
    Ctx.PairIndex.Remove(HeapPair);
    AffectedWords.Free;

    Inc(NextTokenId);
  end;

  Ctx.Words.Free;
  Ctx.PairCounts.Free;
  for IdxList in Ctx.PairIndex.Values do
    IdxList.Free;
  Ctx.PairIndex.Free;
  Ctx.Heap.Free;

end;

end.
