import glob
from pathlib import Path
from snakemake.utils import min_version

##################################
## Helper functions
##################################


def multiglob(patterns):
    files = []
    for pattern in patterns:
        files.extend(glob.glob(pattern))
    return files


def get_all_query_filepaths():
    return multiglob(
        ["queries/*.fa", "queries/*.fq", "queries/*.fasta", "queries/*.fastq"]
    )


def get_all_query_filenames():
    return (Path(file).with_suffix("").name for file in get_all_query_filepaths())


def get_filename_for_all_queries():
    return "___".join(get_all_query_filenames())


##################################
## Initialization
##################################


configfile: "config.yaml"


min_version("6.2.0")
shell.prefix("set -euo pipefail")

batches = [x.strip() for x in open(config["batches"])]
print(f"Batches: {batches}")

qfiles = get_all_query_filepaths()
print(f"Query files: {qfiles}")

assemblies_dir = f"{config['download_dir']}/asms"
cobs_dir = f"{config['download_dir']}/cobs"
decompression_dir = config.get("decompression_dir", "intermediate/00_cobs")


wildcard_constraints:
    batch=".+__\d\d",


if config["keep_cobs_ind"]:

    ruleorder: decompress_cobs > run_cobs > decompress_and_run_cobs


else:

    ruleorder: decompress_and_run_cobs > decompress_cobs > run_cobs


##################################
## Download params
##################################


def cobs_url_fct(wildcards):
    x = wildcards.batch
    if x >= "eubacterium":
        return f"https://zenodo.org/record/6849657/files/{x}.cobs_classic.xz"
    else:
        return f"https://zenodo.org/record/6845083/files/{x}.cobs_classic.xz"


asm_zenodo = 4602622
asms_url = f"https://zenodo.org/record/{asm_zenodo}/files"


##################################
## Top-level rules
##################################


rule all:
    """Run all
    """
    input:
        f"output/{get_filename_for_all_queries()}.sam_summary.xz",


rule download:
    """Download assemblies and COBS indexes.
    """
    input:
        [f"{assemblies_dir}/{x}.tar.xz" for x in batches],
        [f"{cobs_dir}/{x}.cobs_classic.xz" for x in batches],


rule match:
    """Match reads to the COBS indexes.
    """
    input:
        f"intermediate/02_filter/{get_filename_for_all_queries()}.fa",


rule map:
    """Map reads to the assemblies.
    """
    input:
        f"output/{get_filename_for_all_queries()}.sam_summary.xz",


##################################
## Download rules
##################################
rule download_asm_batch:
    """Download compressed assemblies
    """
    output:
        xz=f"{assemblies_dir}/{{batch}}.tar.xz",
    params:
        url=asms_url,
    resources:
        max_download_jobs=1,
    threads: 1
    shell:
        """
        curl "{params.url}/{wildcards.batch}.tar.xz"  > {output.xz}
        scripts/test_xz.py {output.xz}
        """


rule download_cobs_batch:
    """Download compressed cobs indexes
    """
    output:
        xz=f"{cobs_dir}/{{batch}}.cobs_classic.xz",
    params:
        url=cobs_url_fct,
    resources:
        max_download_jobs=1,
    threads: 1
    shell:
        """
        curl "{params.url}"  > {output.xz}
        scripts/test_xz.py {output.xz}
        """


##################################
## Processing rules
##################################
rule fix_query:
    """Fix query to expected COBS format: single line fastas composed of ACGT bases only
    """
    output:
        fixed_query="intermediate/fixed_queries/{qfile}.fa",
    input:
        original_query="queries/{qfile}.fa",
    threads: 1
    conda:
        "envs/seqtk.yaml"
    params:
        base_to_replace="A",
    shell:
        """
        seqtk seq -A -U {input.original_query} \\
            | awk '{{if(NR%2==1){{print $0;}}else{{gsub(/[^ACGT]/, \"{params.base_to_replace}\"); print;}}}}' \\
            > {output.fixed_query}
        """


rule concatenate_queries:
    """Concatenate all queries into a single file, so we just need to run COBS/minimap2 just once per batch
    """
    output:
        concatenated_query=f"intermediate/fixed_queries/{get_filename_for_all_queries()}.fa",
    input:
        all_queries=expand(
            "intermediate/fixed_queries/{qfile}.fa", qfile=get_all_query_filenames()
        ),
    threads: 1
    shell:
        """
        cat {input} > {output}
        """


rule decompress_cobs:
    """Decompress cobs indexes
    """
    output:
        cobs=f"{decompression_dir}/{{batch}}.cobs_classic",
    input:
        xz=f"{cobs_dir}/{{batch}}.cobs_classic.xz",
    resources:
        max_decomp_jobs=1,
    threads: config["cobs_thr"]  # The same number as of COBS threads to ensure that COBS is executed immediately after decompression
    benchmark:
        "logs/benchmarks/decompress_cobs/{batch}.txt"
    shell:
        """
        xzcat "{input.xz}" > "{output.cobs}"
        """


rule run_cobs:
    """Cobs matching
    """
    output:
        match=protected("intermediate/01_match/{batch}____{qfile}.xz"),
    input:
        cobs_index=f"{decompression_dir}/{{batch}}.cobs_classic",
        fa="intermediate/fixed_queries/{qfile}.fa",
    threads: config["cobs_thr"]  # Small number in order to guarantee Snakemake parallelization
    params:
        kmer_thres=config["cobs_kmer_thres"],
    priority: 999
    benchmark:
        "logs/benchmarks/run_cobs/{batch}____{qfile}.txt"
    conda:
        "envs/cobs.yaml"
    shell:
        """
        cobs query \\
            -t {params.kmer_thres} \\
            -T {threads} \\
            -i {input.cobs_index} \\
            -f {input.fa} \\
        | xz -v \\
        > {output.match}
        """


rule decompress_and_run_cobs:
    """Decompress Cobs index and run Cobs matching
    """
    output:
        match=protected("intermediate/01_match/{batch}____{qfile}.xz"),
    input:
        compressed_cobs_index=f"{cobs_dir}/{{batch}}.cobs_classic.xz",
        fa="intermediate/fixed_queries/{qfile}.fa",
    threads: config["cobs_thr"]  # Small number in order to guarantee Snakemake parallelization
    params:
        kmer_thres=config["cobs_kmer_thres"],
        decompression_dir=decompression_dir,
    benchmark:
        "logs/benchmarks/decompress_and_run_cobs/{batch}____{qfile}.txt"
    conda:
        "envs/cobs.yaml"
    shell:
        """
        mkdir -p {params.decompression_dir}
        cobs_index="{params.decompression_dir}/{wildcards.batch}.cobs_classic"
        xzcat "{input.compressed_cobs_index}" > "${{cobs_index}}"
        cobs query \\
            -t {params.kmer_thres} \\
            -T {threads} \\
            -i "${{cobs_index}}" \\
            -f {input.fa} \\
        | xz -v \\
        > {output.match}
        rm -v "${{cobs_index}}"
        """


rule translate_matches:
    """Translate cobs matches.

    Output:
        ref - read - matches
    """
    output:
        fa="intermediate/02_filter/{qfile}.fa",
    input:
        fa="intermediate/fixed_queries/{qfile}.fa",
        all_matches=[
            f"intermediate/01_match/{batch}____{{qfile}}.xz" for batch in batches
        ],
    conda:
        "envs/minimap2.yaml"
    threads: 1
    log:
        "logs/translate_matches/{qfile}.log",
    shell:
        """
        ./scripts/filter_queries.py -q {input.fa} {input.all_matches} \\
            > {output.fa} 2>{log}
        """


rule batch_align_minimap2:
    output:
        sam="intermediate/03_map/{batch}____{qfile}.sam",
    input:
        qfa="intermediate/02_filter/{qfile}.fa",
        asm=f"{assemblies_dir}/{{batch}}.tar.xz",
    log:
        log="logs/03_map/{batch}____{qfile}.log",
    params:
        minimap_preset=config["minimap_preset"],
        minimap_threads=config["minimap_thr"],
        minimap_extra_params=config["minimap_extra_params"],
    conda:
        "envs/minimap2.yaml"
    benchmark:
        "logs/benchmarks/batch_align_minimap2/{batch}____{qfile}.txt"
    threads: config["minimap_thr"]
    shell:
        """
        ((
        ./scripts/batch_align.py \\
            --minimap-preset {params.minimap_preset} \\
            --threads {params.minimap_threads} \\
            --extra-params=\"{params.minimap_extra_params}\" \\
            {input.asm} \\
            {input.qfa} \\
            > {output.sam}
        ) 2>&1 ) > {log}
        """


rule aggregate_sams:
    output:
        pseudosam="output/{qfile}.sam_summary.xz",
    input:
        sam=[f"intermediate/03_map/{batch}____{{qfile}}.sam" for batch in batches],
    threads: 1
    shell:
        """
        head -n 9999999 {input.sam} \\
            | grep -v "@" \\
            | xz \\
            > {output.pseudosam}
        """
