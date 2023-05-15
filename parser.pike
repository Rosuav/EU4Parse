//Parsers - eventually all EU4 text files will be parsed in this file too
mapping(string:Image.Image) image_cache = ([]);
Image.Image|array(Image.Image|int) load_image(string fn, int|void withhash) {
	if (!image_cache[fn]) {
		string raw = Stdio.read_file(fn);
		if (!raw) return withhash ? ({0, 0}) : 0;
		sscanf(Crypto.SHA1.hash(raw), "%20c", int hash);
		function decoder = Image.ANY.decode;
		if (has_suffix(fn, ".tga")) decoder = Image.TGA.decode; //Automatic detection doesn't pick these properly.
		if (has_prefix(raw, "DDS")) {
			//Custom flag symbols, unfortunately, come from a MS DirectDraw file. Pike's image
			//library can't read this format, so we have to get help from ImageMagick.
			mapping rc = Process.run(({"convert", fn, "png:-"}));
			//assert rc=0, stderr=""
			raw = rc->stdout;
			decoder = Image.PNG._decode; //HACK: This actually returns a mapping, not just an image.
		}
		if (catch {image_cache[fn] = ({decoder(raw), hash});}) {
			//Try again via ImageMagick.
			mapping rc = Process.run(({"convert", fn, "png:-"}));
			image_cache[fn] = ({Image.PNG.decode(rc->stdout), hash});
		}
	}
	if (withhash) return image_cache[fn];
	else return image_cache[fn][0];
}
