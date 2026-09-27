unit BPE.Decoder;

{$MODE OBJFPC}{$H+}{$J-}

interface

uses
  SysUtils, Classes, Generics.Collections, BPE.Core; // Ensure TUInt32s is in uses scope

type
  TUInt32s = specialize TList<uint32>;
  TTokenBytesMap = specialize TDictionary<integer, rawbytestring>;
  TSpecialTokenSet = specialize THashSet<integer>;

  { TBPEDecoder }
  TBPEDecoder = class
  private
    FTokenToBytes: TTokenBytesMap;
    FSpecialTokenIds: TSpecialTokenSet;

    procedure BuildLookupTable(AConfig: TBPEConfig);
  public
    constructor Create(AConfig: TBPEConfig);
    destructor Destroy; override;

    // Decodes various collection types into UTF-8 strings
    function Decode(const Tokens: array of integer;
      SkipSpecialTokens: boolean = False): ansistring; overload;
    function Decode(Tokens: TUInt32s; SkipSpecialTokens: boolean = False): ansistring;
      overload;

    // Decodes directly to a raw byte buffer (avoids string allocation overhead)
    function DecodeToBytes(Tokens: TUInt32s;
      SkipSpecialTokens: boolean = False): rawbytestring; overload;
  end;

implementation

{ TBPEDecoder }

constructor TBPEDecoder.Create(AConfig: TBPEConfig);
begin
  inherited Create;

  FTokenToBytes := TTokenBytesMap.Create;
  FSpecialTokenIds := TSpecialTokenSet.Create;
  BuildLookupTable(AConfig);
end;

destructor TBPEDecoder.Destroy;
begin
  FTokenToBytes.Free;
  FSpecialTokenIds.Free;
  inherited;
end;

procedure TBPEDecoder.BuildLookupTable(AConfig: TBPEConfig);
var
  SpecName: string;
  SpecId, b, i: integer;
  Merge: TBPEConfig.TBPEPairMerge;
  LeftBytes, RightBytes: rawbytestring;
begin
  for SpecName in AConfig.SpecialTokens.Keys do
  begin
    SpecId := AConfig.SpecialTokens[SpecName];
    FSpecialTokenIds.Add(SpecId);
    FTokenToBytes.Add(SpecId, rawbytestring(SpecName));
  end;

  for b := 0 to 255 do
    FTokenToBytes.Add(AConfig.ByteOffset + b, rawbytestring(Chr(b)));

  // Expand merges in creation order
  for i := 0 to AConfig.Merges.Count - 1 do
  begin
    Merge := AConfig.Merges[i];
    if FTokenToBytes.TryGetValue(Merge.LeftToken, LeftBytes) and
      FTokenToBytes.TryGetValue(Merge.RightToken, RightBytes) then
    begin
      FTokenToBytes.Add(Merge.NewTokenId, LeftBytes + RightBytes);
    end;
  end;
end;

function TBPEDecoder.DecodeToBytes(Tokens: TUInt32s;
  SkipSpecialTokens: boolean = False): rawbytestring;
var
  i, TokenId: integer;
  TokenBytes: rawbytestring;
begin
  Result := '';
  if (Tokens = nil) or (Tokens.Count = 0) then Exit;

  for i := 0 to Tokens.Count - 1 do
  begin
    TokenId := Tokens[i];

    if FSpecialTokenIds.Contains(TokenId) then
    begin
      if not SkipSpecialTokens then
        if FTokenToBytes.TryGetValue(TokenId, TokenBytes) then
          Result := Result + TokenBytes;
      Continue;
    end;

    if FTokenToBytes.TryGetValue(TokenId, TokenBytes) then
    begin
      if (Length(TokenBytes) > 0) and (TokenBytes[1] = BPE.CORE.SpacePrefix) then
        Result := Result + ' ' + Copy(TokenBytes, 2, Length(TokenBytes) - 1)
      else
        Result := Result + TokenBytes;
    end;
  end;
end;

function TBPEDecoder.Decode(Tokens: TUInt32s; SkipSpecialTokens: boolean): ansistring;
var
  RawBytes: rawbytestring;
begin
  RawBytes := DecodeToBytes(Tokens, SkipSpecialTokens);
  SetCodePage(rawbytestring(RawBytes), CP_UTF8, False);
  Result := ansistring(RawBytes);
end;

function TBPEDecoder.Decode(const Tokens: array of integer;
  SkipSpecialTokens: boolean): ansistring;
var
  List: TUInt32s;
  i: integer;
begin
  List := TUInt32s.Create;
  List.Count := Length(Tokens); // Assuming TUInt32s supports Count sizing
  for i := 0 to High(Tokens) do
    List[i] := Tokens[i];
  Result := Decode(List, SkipSpecialTokens);
  List.Free;
end;

end.
