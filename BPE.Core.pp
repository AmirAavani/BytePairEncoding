unit BPE.Core;

{$MODE OBJFPC}{$H+}{$J-}
{$modeswitch ADVANCEDRECORDS}

interface

uses
  SysUtils, Classes, Generics.Collections;

type
  TTokenPair = uint64;

function MakePair(Left, Right: integer): TTokenPair; inline;
procedure SplitPair(Pair: TTokenPair; out Left, Right: integer); inline;

type
  TBPEPairMerge = record
    LeftToken: integer;
    RightToken: integer;
    NewTokenId: integer;
  end;

  TBPEPairMergeList = specialize TList<TBPEPairMerge>;
  TSpecialTokenMap = specialize TDictionary<string, integer>;
  TWordDictionary = specialize TDictionary<string, integer>;

  { TBPEConfig }
  // Holds the learned BPE vocabulary state, special tokens, and serialization logic.
  TBPEConfig = class
  private
    FSpecialTokens: TSpecialTokenMap;
    FMerges: TBPEPairMergeList;
    FVocabSize: integer;
    FByteOffset: integer;
  public
    constructor Create;
    constructor CreateFromStream(AStream: TStream);
    destructor Destroy; override;

    procedure SaveToStream(AStream: TStream);
    procedure LoadFromStream(AStream: TStream);

    property SpecialTokens: TSpecialTokenMap read FSpecialTokens;
    property Merges: TBPEPairMergeList read FMerges;
    property VocabSize: integer read FVocabSize write FVocabSize;
    property ByteOffset: integer read FByteOffset write FByteOffset;
  end;

implementation
uses
  fpjson, jsonparser, jsonscanner;

function MakePair(Left, Right: integer): TTokenPair; inline;
begin
  Result := (uint64(cardinal(Left)) shl 32) or uint64(cardinal(Right));
end;

procedure SplitPair(Pair: TTokenPair; out Left, Right: integer); inline;
begin
  Left := integer(Pair shr 32);
  Right := integer(Pair and $FFFFFFFF);
end;

{ Helper stream procedures for String and Data writing }

procedure WriteString(AStream: TStream; const S: string);
var
  Len: integer;
begin
  Len := Length(S);
  AStream.WriteBuffer(Len, SizeOf(integer));
  if Len > 0 then
    AStream.WriteBuffer(S[1], Len);
end;

function ReadString(AStream: TStream): string;
var
  Len: integer;
begin
  AStream.ReadBuffer(Len, SizeOf(integer));
  if Len > 0 then
  begin
    SetLength(Result, Len);
    AStream.ReadBuffer(Result[1], Len);
  end
  else
    Result := '';
end;

{ TBPEConfig }

constructor TBPEConfig.Create;
begin
  FSpecialTokens := TSpecialTokenMap.Create;
  FMerges := TBPEPairMergeList.Create;
  FVocabSize := 0;
  FByteOffset := 0;
end;

constructor TBPEConfig.CreateFromStream(AStream: TStream);
begin
  Create;
  LoadFromStream(AStream);
end;

destructor TBPEConfig.Destroy;
begin
  FSpecialTokens.Free;
  FMerges.Free;
  inherited;
end;

procedure TBPEConfig.SaveToStream(AStream: TStream);
var
  Root, SpecialObj, MergeObj: TJSONObject;
  MergesArr: TJSONArray;
  Key: string;
  Merge: TBPEPairMerge;
  i: Integer;
  JSONStr: string;
begin
  Root := TJSONObject.Create;
  try
    // 1. Core Configuration
    Root.Add('vocab_size', FVocabSize);
    Root.Add('byte_offset', FByteOffset);

    // 2. Special Tokens
    SpecialObj := TJSONObject.Create;
    for Key in FSpecialTokens.Keys do
      SpecialObj.Add(Key, FSpecialTokens[Key]);
    Root.Add('special_tokens', SpecialObj);

    // 3. Merges
    MergesArr := TJSONArray.Create;
    for i := 0 to FMerges.Count - 1 do
    begin
      Merge := FMerges[i];
      MergeObj := TJSONObject.Create;
      MergeObj.Add('left', Merge.LeftToken);
      MergeObj.Add('right', Merge.RightToken);
      MergeObj.Add('new_id', Merge.NewTokenId);
      MergesArr.Add(MergeObj);
    end;
    Root.Add('merges', MergesArr);

    // Write to stream as a UTF-8 string
    JSONStr := Root.AsJSON;
    if Length(JSONStr) > 0 then
      AStream.WriteBuffer(JSONStr[1], Length(JSONStr));
  finally
    Root.Free;
  end;
end;

procedure TBPEConfig.LoadFromStream(AStream: TStream);
var
  Parser: TJSONParser;
  Root, SpecialObj, MergeObj: TJSONObject;
  MergesArr: TJSONArray;
  i: Integer;
  Merge: TBPEPairMerge;
begin
  FSpecialTokens.Clear;
  FMerges.Clear;

  Parser := TJSONParser.Create(AStream, [joUTF8, joIgnoreTrailingComma]);
  try
    Root := Parser.Parse as TJSONObject;
    try
      // 1. Core Configuration
      FVocabSize := Root.Integers['vocab_size'];
      FByteOffset := Root.Integers['byte_offset'];

      // 2. Special Tokens
      SpecialObj := Root.Objects['special_tokens'];
      for i := 0 to SpecialObj.Count - 1 do
      begin
        // Add(Key, Value)
        FSpecialTokens.Add(SpecialObj.Names[i], SpecialObj.Items[i].AsInteger);
      end;

      // 3. Merges
      MergesArr := Root.Arrays['merges'];
      for i := 0 to MergesArr.Count - 1 do
      begin
        MergeObj := MergesArr.Objects[i];
        Merge.LeftToken := MergeObj.Integers['left'];
        Merge.RightToken := MergeObj.Integers['right'];
        Merge.NewTokenId := MergeObj.Integers['new_id'];
        FMerges.Add(Merge);
      end;
    finally
      Root.Free;
    end;
  finally
    Parser.Free;
  end;
end;

end.
