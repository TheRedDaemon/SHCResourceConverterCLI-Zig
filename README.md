# SHCResourceConverterCLI-Zig
This CLI tool was created in an attempt to analyze the graphic formats of Stronghold Crusader.

There is no manual for this tool. But using `-h` or `--help` should give you a general direction. Notice, that the subcommands have a separate help.

Consider that the exported format is a custom raw format that tries to leave all information intact. For this reason, the transparency information is even put into a different file, since there is no way to know for certain if the color indexed files have a transparency index to use or if the ARGB files respect their alpha channel.

## Discoveries

### TGX Format
The general TGX format is not explained here. There are other sources found online.
  * Data content is always padded to multiples of 4 byte. (Padded to 4 byte alignment.)
  * The threshold for using repeating pixels seems to be 3 pixels with the same color. This check appears to be not restricted by any constrains of the image, may it be a line jump or exceeding the image width on a bigger canvas (relevant for GM1). This results in repeated pixels that might make not sense if only the image itself if considered.
  * The usage of the magenta marker is still unclear, with the following analyzing the ARGB1555 to RGB565 function used by TGX files:
    * If the current pixel batch is of "streamed pixels", basically saying "after me there are is number of uncompressed pixels", then the color `0b1111100000011111` should NOT be transformed.
    * `0b1111100000011111` is basically magenta in RGB565 format. How this should get in there and what the real purpose of it is is still not known.
### GM1 Files
  * What was called "animatedColor" in the CrossConverter seems to be a collection of flags, mostly unused or broken in the game itself. In the end, the only relevant flag remaining is likely the 4 bit flag, which might just indicate to not load the image. How all other code avoids using these indexes then is unknown to me. Maybe meta structures not present anymore.
  * Based on tests, the image headers seem to use two union like structures, one for tile objects, and one for everything else.
  * The tile object structure allows to have a crowning image for every tile, while the game only uses them on the upper tiles.
    * With a bit of trickery in the used data, the images might still be placeable on a 2D plane while not actually being able to be placed like present in the game. 
    * The important part is that `tileoffset + 7` is used to get the image size, but `image height in header - tile height + 7` would also be valid, but could be adjusted to indicate a bigger image on 2D.
    * The xOffset also starts always from the left side, regardless of the crowning image position enum.
    * Adding images to tiles in the front of a build and moving these with `tileoffset` and `xOffset` might allow to produce some broken/interesting/strange effects. The plane where units are hidden seems to be at the upper end of the tile.
  * The TGX encoding for tile images is performed without at least the current tile being present on the canvas. If the canvas was only the current combined image or if all tiles were removed can only be guessed.
  * While ARGB formats likely considered their alpha channel, animations actually have no direct alpha channel in their source. However, it is likely that the 0 index was considered the alpha marker. Manually checked palette data had a magenta color there.  
  To be absolutely sure, all animation files would need to be checked to not contain an 0 index in der pixels stream and repeating pixel data. **This check was not performed.**
  * Animation and Const-TGX GM1 files appear to have had a grid in their sources data, which were considered in their TGX transform.
    * The Const-TGX files seem to use a simple black (`0b1000000000000000`).
    * The animation files that are effected in their encoding by this are mostly using the index `0x1`. There is one exception, which the current default settings can therefore not recreate: `body_trebutchet.gm1`. This one uses the index `0xff` for the grid. One can only guess:
      * The file simply was created differently than the others.
      * It might be related to the quantization or technic they used to create the color tables and indexes. If their algorithm worked on the whole file, it might have simply decided to use this different index. It can even be possible that other images that used a grid might have had another index for the grid, but they left no trace in the image encoding. This one could only be guessed if someone would take the challenge and tries to recreate the quantization.

# Conclusion
There was was barely any discovery on the way the games handles these formats, while there are still questions left. Regardless, it is interesting which traces like the grid can still be found. The latter only through the missing constrains of the encoding.
