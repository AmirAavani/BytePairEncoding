program Trainer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes,
  BPE.Trainer, BPE.Core;

var
  Dict: TWordDictionary;
  Config, LoadedConfig: TBPEConfig;
  FileStream: TFileStream;
begin
  Dict := TWordDictionary.Create;
  Dict.Add('running', 100);
  Dict.Add('runner', 50);

  Config := TBPETrainer.Train(Dict, 300, ['<pad>', '<bos>', '<eos>']);
  Dict.Free;
  FileStream := TFileStream.Create('bpe_model.json', fmCreate);
  Config.SaveToStream(FileStream);
  FileStream.Free;
  Config.Free;

  FileStream := TFileStream.Create('bpe_model.json', fmOpenRead);
  LoadedConfig := TBPEConfig.CreateFromStream(FileStream);
  WriteLn('Loaded merges count: ', LoadedConfig.Merges.Count);
  WriteLn('Special token <bos> ID: ', LoadedConfig.SpecialTokens['<bos>']);
  LoadedConfig.Free;
  FileStream.Free;
end.
