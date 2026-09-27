unit BPE.Encoder;

{$MODE OBJFPC}{$H+}{$J-}

interface

uses
  SysUtils, Classes, Generics.Collections, BPE.Core;

type
  TPairRankMap = specialize TDictionary<TTokenPair, integer>;
  TPairNewIdMap = specialize TDictionary<TTokenPair, integer>;
  TIntegerList = specialize TList<uint32>;

  { TBPEEncoder }
  TBPEEncoder = class
  private
    FByteOffset: integer;
    FRankMap: TPairRankMap;
    FNewIdMap: TPairNewIdMap;
    FSpecialTokens: TBPEConfig.TSpecialTokenMap;

    procedure BuildRankMaps(AConfig: TBPEConfig);
    procedure MergeWordTokens(Tokens: TIntegerList);
  public
    constructor Create(AConfig: TBPEConfig);
    destructor Destroy; override;

    // Encodes a single token/word string using a provided reusable buffer
    procedure EncodeWord(const WordStr: ansistring; Tokens: TIntegerList);

    // Encodes full text into an array of token IDs
    function Encode(const Text: ansistring; OutputList: TIntegerList): integer; overload;
    function GetSpecialTokenID(const TokenName: string): UInt32;
  end;

implementation

{ TBPEEncoder }

constructor TBPEEncoder.Create(AConfig: TBPEConfig);
begin
  FRankMap := TPairRankMap.Create;
  FNewIdMap := TPairNewIdMap.Create;
  FSpecialTokens := TBPEConfig.TSpecialTokenMap.Create;
  FByteOffset := AConfig.ByteOffset;

  BuildRankMaps(AConfig);
end;

destructor TBPEEncoder.Destroy;
begin
  FRankMap.Free;
  FNewIdMap.Free;
  FSpecialTokens.Free;
  inherited;
end;

procedure TBPEEncoder.BuildRankMaps(AConfig: TBPEConfig);
var
  i: integer;
  Merge: TBPEConfig.TBPEPairMerge;
  Pair: TTokenPair;
  Key: ansistring;
begin
  for Key in AConfig.SpecialTokens.Keys do
    FSpecialTokens.Add(Key, AConfig.SpecialTokens[Key]);

  for i := 0 to AConfig.Merges.Count - 1 do
  begin
    Merge := AConfig.Merges[i];
    Pair := MakePair(Merge.LeftToken, Merge.RightToken);
    FRankMap.Add(Pair, i);
    FNewIdMap.Add(Pair, Merge.NewTokenId);
  end;
end;

procedure TBPEEncoder.MergeWordTokens(Tokens: TIntegerList);
var
  i, MinRank, MinIdx, Rank, NewId: integer;
  Pair, TargetPair: TTokenPair;
  TargetLeft, TargetRight: integer;
begin
  if Tokens.Count < 2 then Exit;

  while Tokens.Count >= 2 do
  begin
    MinRank := High(integer);
    MinIdx := -1;

    for i := 0 to Tokens.Count - 2 do
    begin
      Pair := MakePair(Tokens[i], Tokens[i + 1]);
      if FRankMap.TryGetValue(Pair, Rank) then
      begin
        if Rank < MinRank then
        begin
          MinRank := Rank;
          MinIdx := i;
        end;
      end;
    end;

    if MinIdx = -1 then Break;

    TargetPair := MakePair(Tokens[MinIdx], Tokens[MinIdx + 1]);
    SplitPair(TargetPair, TargetLeft, TargetRight);
    NewId := FNewIdMap[TargetPair];

    i := 0;
    while i < Tokens.Count - 1 do
    begin
      if (Tokens[i] = TargetLeft) and (Tokens[i + 1] = TargetRight) then
      begin
        Tokens[i] := NewId;
        Tokens.Delete(i + 1);
      end;
      Inc(i);
    end;
  end;
end;

procedure TBPEEncoder.EncodeWord(const WordStr: ansistring; Tokens: TIntegerList);
var
  i: integer;
begin
  Tokens.Clear;
  if Length(WordStr) = 0 then Exit;

  // Populate initial byte-level tokens
  for i := 1 to Length(WordStr) do
    Tokens.Add(FByteOffset + Ord(WordStr[i]));

  // Apply learned merge rules in-place
  MergeWordTokens(Tokens);
end;

function TBPEEncoder.Encode(const Text: ansistring; OutputList: TIntegerList
  ): integer;
var
  PCH, Start: pchar;
  WordStr: rawbytestring;
  TempWordTokens: TIntegerList;
  i: integer;
  WordLen: SizeInt;
begin
  Result := 0;
  if Length(Text) = 0 then Exit;

  PCH := PChar(Text);
  Start := PCH;

  TempWordTokens := TIntegerList.Create;
  while PCH^ <> #0 do
  begin
    if (PCH^ = #10) or (PCH^ = #13) or (PCH^ = ' ') or (PCH^ = #9) then
    begin
      WordLen := PCH - Start;
      if WordLen > 0 then
      begin
        SetLength(WordStr, WordLen + 1);
        WordStr[1] := BPE.CORE.SpacePrefix;
        Move(Start^, WordStr[2], WordLen);

        EncodeWord(WordStr, TempWordTokens);

        for i := 0 to TempWordTokens.Count - 1 do
          OutputList.Add(TempWordTokens[i]);

        Inc(Result, TempWordTokens.Count);
      end;

      Start := PCH + 1;
    end;
    Inc(PCH);
  end;

  WordLen := PCH - Start;
  if WordLen > 0 then
  begin
    SetLength(WordStr, WordLen + 1);
    WordStr[1] := BPE.CORE.SpacePrefix;
    Move(Start^, WordStr[2], WordLen);

    EncodeWord(WordStr, TempWordTokens);

    for i := 0 to TempWordTokens.Count - 1 do
      OutputList.Add(TempWordTokens[i]);

    Inc(Result, TempWordTokens.Count);
  end;

  TempWordTokens.Free;
end;

function TBPEEncoder.GetSpecialTokenID(const TokenName: string): UInt32;
begin
  if not FSpecialTokens.TryGetValue(TokenName, Result) then
    Result := -1;
end;

end.
