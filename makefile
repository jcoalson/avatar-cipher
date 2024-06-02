# To test, try
#
#   printf "Hello\nworld" | gnumake && ls output/
#

output/example.png: output/example.pbm
	convert $< -strip $@
	# make green terminal-colored versions:
	convert -size 1x2 gradient:black-green output/gradient_levels.png
	convert -size 1x2 gradient:black-'#00c800' output/gradient_levels_bright.png
	convert $@ -negate output/gradient_levels.png -clut $(basename $@).terminal$(suffix $@)
	convert $@ -negate output/gradient_levels_bright.png -clut $(basename $@).terminal-bright$(suffix $@)
	rm output/gradient_levels.png output/gradient_levels_bright.png

output/example.pbm: encode.pl hints/hint-110010.pbm secret.txt fonts/font-5x5.txt
	mkdir -p $(@D)
	./$< -H $(filter-out $<,$^) $@

secret.txt:
	printf "1\n1\n0\n0\n1\n0\n" > $@

clean:
	rm secret.txt
