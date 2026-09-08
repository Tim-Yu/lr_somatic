process SAVANA {
    tag "$meta.id"
    label 'process_high'
    label 'process_long'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine in ['singularity', 'apptainer'] && !task.ext.singularity_pull_docker_container ?
        'https://depot.galaxyproject.org/singularity/savana:1.3.8--pyhdfd78af_0':
        'biocontainers/savana:1.3.8--pyhdfd78af_0' }"

    input:
    // normal_* and snp_vcf/snp_tbi may be [] (tumour-only mode -> `savana to`)
    tuple val(meta), path(tumour_bam), path(tumour_bai), path(normal_bam), path(normal_bai), path(snp_vcf), path(snp_tbi)
    tuple val(meta2), path(fasta)
    tuple val(meta3), path(fai)
    tuple val(meta4), path(contigs), path(blacklist)
    val(g1000_vcf)  // '1000g_hg38' | '1000g_t2t' | '1000g_hg19' | '' (none)

    output:
    // SV calling + classification
    tuple val(meta), path("${prefix}.sv_breakpoints.vcf.gz")                      , emit: sv_breakpoints_vcf
    tuple val(meta), path("${prefix}.sv_breakpoints.vcf.gz.tbi")                  , emit: sv_breakpoints_tbi
    tuple val(meta), path("${prefix}.sv_breakpoints.bedpe")                       , emit: sv_breakpoints_bedpe
    tuple val(meta), path("${prefix}.sv_breakpoints_read_support.tsv")            , emit: read_support
    tuple val(meta), path("${prefix}.inserted_sequences.fa")                      , emit: inserted_sequences
    tuple val(meta), path("${prefix}.classified.vcf.gz")                          , emit: classified_vcf
    tuple val(meta), path("${prefix}.classified.vcf.gz.tbi")                      , emit: classified_tbi
    tuple val(meta), path("${prefix}.classified.somatic.vcf.gz")                  , emit: somatic_vcf
    tuple val(meta), path("${prefix}.classified.somatic.vcf.gz.tbi")              , emit: somatic_tbi
    tuple val(meta), path("${prefix}.classified.somatic.bedpe")                   , emit: somatic_bedpe
    tuple val(meta), path("${prefix}.classified.{strict,lenient}.vcf")            , emit: legacy_vcfs          , optional: true
    // Copy number (only produced when an SNP source is available)
    tuple val(meta), path("${prefix}_allele_counts_hetSNPs.bed")                  , emit: allele_counts        , optional: true
    tuple val(meta), path("${prefix}_raw_read_counts.tsv")                        , emit: raw_read_counts      , optional: true
    tuple val(meta), path("${prefix}_read_counts_*_log2r_segmented.tsv")          , emit: segmented_log2r      , optional: true
    tuple val(meta), path("${prefix}_ranked_solutions.tsv")                       , emit: ranked_solutions     , optional: true
    tuple val(meta), path("${prefix}_fitted_purity_ploidy.tsv")                   , emit: fitted_purity_ploidy , optional: true
    tuple val(meta), path("${prefix}_segmented_absolute_copy_number.tsv")         , emit: cna                  , optional: true
    tuple val(meta), path("*kbp_bin_ref_*_${prefix}*.bed")                        , emit: binned_ref           , optional: true
    tuple val(meta), path("No_fit_found_PARAMS.tsv")                              , emit: no_fit               , optional: true
    tuple val(meta), path("${prefix}.contigs.txt")                                , emit: contigs_used
    path "versions.yml"                                                           , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    prefix = task.ext.prefix ?: "${meta.id}"

    def tumour_only  = !normal_bam
    def subcommand   = tumour_only ? "to" : ""
    def normal_arg   = tumour_only ? "" : "--normal ${normal_bam}"
    // Allele counting source for CNA: matched-germline SNP VCF preferred, otherwise bundled 1000G panel
    def allele_arg   = snp_vcf ? "--snp_vcf ${snp_vcf}" : (g1000_vcf ? "--g1000_vcf ${g1000_vcf}" : "")
    def blacklist_arg = blacklist ? "--blacklist ${blacklist}" : ""
    // Restrict to canonical chromosomes unless a contigs file is supplied; drop chrY for females
    def contig_regex = meta.sex == 'female' ? '^(chr)?([0-9]+|X)$' : '^(chr)?([0-9]+|X|Y)$'
    def contigs_cmd  = contigs
        ? "cp ${contigs} ${prefix}.contigs.txt"
        : "cut -f1 ${fai} | { grep -E '${contig_regex}' || true; } > ${prefix}.contigs.txt\n    [ -s ${prefix}.contigs.txt ] || cut -f1 ${fai} >| ${prefix}.contigs.txt"

    """
    ${contigs_cmd}

    # SAVANA's copy-number step ignores --contigs and defaults to chr1-22,X,Y (KeyError on references that
    # lack any of them). Give it the canonical subset of the same contigs as chromosome numbers (X=23, Y=24).
    cna_chroms=\$(sed -E 's/^chr//' ${prefix}.contigs.txt | awk '\$1 ~ /^([0-9]+|X|Y)\$/ { sub(/^X\$/, "23"); sub(/^Y\$/, "24"); printf "%s ", \$1 }')

    savana ${subcommand} \\
        --tumour ${tumour_bam} \\
        ${normal_arg} \\
        --ref ${fasta} \\
        --ref_index ${fai} \\
        --contigs ${prefix}.contigs.txt \\
        \${cna_chroms:+--chromosomes \$cna_chroms} \\
        --outdir savana_out \\
        --tmpdir savana_tmp \\
        --sample ${prefix} \\
        --threads ${task.cpus} \\
        --cna_threads ${task.cpus} \\
        ${allele_arg} \\
        ${blacklist_arg} \\
        ${args}

    mv savana_out/* .
    rmdir savana_out
    rm -rf savana_tmp

    for vcf in ${prefix}.sv_breakpoints.vcf ${prefix}.classified.vcf ${prefix}.classified.somatic.vcf; do
        bgzip -@ ${task.cpus} \$vcf
        tabix -p vcf \$vcf.gz
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        savana: \$(savana --version 2>&1 | sed -n 's/^SAVANA //p')
    END_VERSIONS
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    def cna_outputs = (snp_vcf || g1000_vcf) ? """
    touch ${prefix}_allele_counts_hetSNPs.bed
    touch ${prefix}_raw_read_counts.tsv
    touch ${prefix}_read_counts_mnorm_log2r_segmented.tsv
    touch ${prefix}_ranked_solutions.tsv
    touch ${prefix}_fitted_purity_ploidy.tsv
    touch ${prefix}_segmented_absolute_copy_number.tsv
    touch 10kbp_bin_ref_all_${prefix}_with_SV_breakpoints.bed
    """ : ""

    """
    touch ${prefix}.contigs.txt
    echo | gzip > ${prefix}.sv_breakpoints.vcf.gz
    touch ${prefix}.sv_breakpoints.vcf.gz.tbi
    touch ${prefix}.sv_breakpoints.bedpe
    touch ${prefix}.sv_breakpoints_read_support.tsv
    touch ${prefix}.inserted_sequences.fa
    echo | gzip > ${prefix}.classified.vcf.gz
    touch ${prefix}.classified.vcf.gz.tbi
    echo | gzip > ${prefix}.classified.somatic.vcf.gz
    touch ${prefix}.classified.somatic.vcf.gz.tbi
    touch ${prefix}.classified.somatic.bedpe
    ${cna_outputs}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        savana: 1.3.8
    END_VERSIONS
    """
}
